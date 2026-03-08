# F2ベース HPC Ad-hoc Filesystem Metadata KVS 設計ドキュメント

## 1. 概要

本ドキュメントは、HPCアドホックファイルシステム向けメタデータKVSの設計をまとめたものである。
Microsoft Research の FASTER / F2 をベースとし、シングルスレッド非同期I/O（io_uring）アーキテクチャ上で、
HybridLog、Blob Extent統合、およびSnapshot機構を実現する。

### 設計原則

- **シングルスレッド + async io_uring**: 並行制御のコストをゼロにし、全操作をイベントループ上のステートマシンとして駆動する
- **F2ベースのストレージエンジン**: Hot/Cold 2-tier HybridLog + chained hash index による高性能なpoint操作
- **Blob Extent統合**: メタデータとチャンクデータを統一的なKVSインターフェースで管理する
- **Snapshot機構**: PFSへの非同期stage-outのため、一貫したバージョンのスナップショットを提供する

---

## 2. ストレージエンジン: F2ベースHybridLog

### 2.1 Hash Index

F2と同様のlatch-free chained hash indexを採用する。

- バケットエントリ: 8バイト（tag 15bit + address 48bit + tentative 1bit）
- キー本体はindexに持たず、HybridLog上のレコードに格納する
- tagにより実効的なhash解像度を k+15 bit に拡張し、不要なHybridLogアクセスを削減する
- シングルスレッドのため、tentative bitやCAS操作は不要となり、実装が大幅に簡略化される

バケットサイズは64バイト（キャッシュライン）で、7エントリ + 1 overflow bucket pointerで構成される。
バケット数をキー数に対して十分に確保すれば、hash chainの長さはほぼ1に収まる。
15 bitのtagによりchain内でのtag衝突確率は1/32768であり、
実用上ほとんどの操作はindex lookup → 1回のレコード読みで完結する。

### 2.2 レコードフォーマット

FASTER準拠のレコードフォーマットを採用する。

```
Record Layout:
  ┌──────────────────────────────────────────────────────┐
  │ Record Header (8 bytes)                               │
  │   previous_address: 48 bit  (hash chain pointer)      │
  │   invalid:          1 bit                             │
  │   tombstone:        1 bit                             │
  │   reserved:         14 bit                            │
  ├──────────────────────────────────────────────────────┤
  │ Version (4 bytes)                                     │
  │   version:          u32  (snapshot version, 単調増加)  │
  ├──────────────────────────────────────────────────────┤
  │ Key (variable length, 最大4KiB)                       │
  │   dirname_len: u16                                    │
  │   dirname:     [u8; dirname_len]                      │
  │   filename_len: u16                                   │
  │   filename:    [u8; filename_len]                     │
  ├──────────────────────────────────────────────────────┤
  │ Value                                                 │
  │   metadata:       Metadata (fixed size, app定義)       │
  │   extent_addr:    u64  (0xFFFFFFFFFFFFFFFF = 未割当)  │
  │   extent_length:  u32  (4KiB単位のブロック数)           │
  └──────────────────────────────────────────────────────┘
```

- **previous_address:** hash chain内の前のレコードのlog address。chain終端は0。
- **invalid bit:** compactionやRCU失敗時にレコードを無効化するために使用。
- **tombstone bit:** deleteされたレコードを示す。
- **version:** snapshot version番号（u32、単調増加）。mark_snapshotごとにglobal versionが
  インクリメントされ、レコード作成・更新時に現在のglobal versionが記録される。
  version 0に特別な意味はなく、初期状態から有効な値として使用される。
- **Key:** dirname + filenameの複合キー。各コンポーネントの最大長はPOSIX準拠で合計最大4KiB。
  Primary HybridLogとSecondary HybridLogで同じhash関数を使用する。
- **extent_addr:** チャンクデータのディスク上の開始位置。0xFFFFFFFFFFFFFFFFは未割り当てを示す。
- **extent_length:** チャンクサイズを4KiBブロック数で表現。

### 2.3 HybridLog: Hot/Cold 2-Tier構成

F2のアーキテクチャに基づき、Hot LogとCold Logの2層構成を採用する。

**Hot Log** はFASTERのHybridLogと同じ構造を持つ。

- Mutable Region（メモリ上）: in-place更新可能
- Read-Only Region（メモリ上）: immutable、更新時はRCUでtailに新レコード追記
- Stable Region（ディスク上）: flushされたページ

Hot Logにはwrite-hotなレコードのみが滞在し、hot-cold compactionにより
coldレコードはCold Logに移される。

**Cold Log** はほぼ全てがディスク上に配置される。
アクセスにはcold-log indexのhash chunk読み出し + レコード本体読み出しの
最低2回のI/Oが必要となる。

**2-Tier構成の利点:**

- FASTERの "death spiral" 問題を解消: coldレコードのcompaction先がcold log tailであり、hot log tailと競合しない
- write-hotレコードとwrite-coldレコードの物理的分離により、hot logのメモリ効率が向上する
- read-hotだがwrite-coldなレコードはread cacheで対応する

### 2.4 Cold-Log Index

F2と同様の2-level hash index設計を採用する。

- 1st level: メモリ上のhash table（hash chunkへのポインタ）
- 2nd level: ディスク上のhash chunk log（各chunkに32エントリ、256バイト）
- coldキー1つあたり1バイト未満のメモリオーバーヘッドでbillion-keyスケールに対応する

hash chunkの更新はF2と同様にhash chunk logへのRMWで行う。
hot-cold compactionでレコードがcold logに移った際、
対応するhash chunkにエントリを追加するRMWが発行される。
hash chunk logはHybridLogインスタンスとして管理され、
小さなin-memory regionを持つ。

### 2.5 Read Cache

Hot-log indexのhash chainを拡張し、read cacheレコードも含む構成とする。

- ディスクからreadしたレコードのコピーをread cacheに格納する
- Second-Chance FIFOに類似したeviction方式を用いる
- RMW/Delete時にはread cacheの該当エントリを無効化する

### 2.6 Page Flush機構

FASTER/F2のHybridLogをシングルスレッド + 非同期I/O向けに簡略化したpage flush機構を実装する。

**アドレス管理:**

HybridLogのcircular bufferは以下の単調増加するアドレスで管理される。

```
[BEGIN ................ HEAD .......... READ-ONLY ........... TAIL]
 ↑ ログ先頭            ↑ メモリ境界    ↑ mutable境界         ↑ ログ末尾
 (truncate済み)        (これ以上が     (これ以上が            (新レコード追記)
                       メモリ上)       in-place更新可能)
```

- **BEGIN:** ログの先頭。これより前のレコードは無効（compactionでtruncate済み）。
- **HEAD offset:** メモリ上に存在する最も古いアドレス。circular buffer上にマッピングされる。
- **Read-only offset:** mutable regionとread-only regionの境界。
- **TAIL offset:** ログの末尾。新しいレコードはここに追記される。

FASTERではsafe read-only offset（全スレッドが認識したread-only offsetの最小値）と
fuzzy regionの管理が必要だが、シングルスレッドではoffset更新が即座に全操作に反映されるため、
safe read-only offsetとfuzzy regionの概念は不要である。

**ページ状態遷移:**

circular buffer内の各ページフレームは、chunk cacheのblock状態と同じパターンで
状態遷移する。

```
page状態:
  Free    → 未使用。新しいページフレームとして割り当て可能。
  Mutable → tail付近。レコードのin-place更新が可能。
  ReadOnly → read-only region内。immutable。flush対象。
  Flushing → async flush I/O中（Pinned相当）。evict不可。
  Clean   → flush完了。ディスクと同じ内容。evict可能。
  Evicted → evict済み。circular bufferのスロットはFreeに戻る。
```

```
状態遷移:
  Free → Mutable     : tail offsetがこのページに到達
  Mutable → ReadOnly : read-only offsetがこのページを超過
  ReadOnly → Flushing: async flush SQE発行
  Flushing → Clean   : flush CQE返却（I/O完了）
  Clean → Evicted    : head offsetがこのページを超過（ページフレーム再利用）
  Evicted → Free     : circular bufferのスロットとして再利用可能に
```

**Flushの流れ:**

シングルスレッドではFASTERのepoch-based trigger actionの代わりに、
tail offsetの成長に伴い直接的にflush処理を行う。

```
tail offsetがページ境界を超えた時:
  1. read-only offsetを更新（tail - ro_lag）
     → 新たにread-onlyになったページが発生

  2. 新たにread-onlyになったページに対してflush SQE発行
     → ページ状態: ReadOnly → Flushing

  3. head offsetの更新が必要か確認（circular buffer容量）
     → 必要なら: 対象ページがClean状態であることを確認
     → Cleanなら: head offsetを更新、ページをEvicted → Free
     → Flushingなら: flush完了を待つ（次のpollで再試行）

CQE返却時:
  → 対象ページ状態: Flushing → Clean
  → head offset更新待ちがあれば、次のpoll Stepで処理
```

**Allocate:**

FASTERのfetch-and-addベースのAllocateをシングルスレッド向けに簡略化する。

```
allocate(size):
  if tail_offset + size がページ内に収まる:
    addr = tail_offset
    tail_offset += size
    return addr

  // ページ境界超過
  次のページフレームを準備:
    次のスロットがFree状態であることを確認
    → Freeでない場合: flush/evictionを進めてFreeになるまで待つ
       （バッファ確保待ちキューに中断）
    ページ状態: Free → Mutable
  
  read-only offset / head offset更新
  flush SQE発行（必要なら）
  
  addr = 新ページの先頭
  tail_offset = addr + size
  return addr
```

ページフレームが確保できない場合（全ページがFlushing中など）は、
chunk cacheのバッファ確保待ちと同じメカニズムでpage buffer queueに中断される。
flush I/O完了でページがClean → Evicted → Freeになれば再開される。

**Read Cacheのページ管理:**

Read cacheもHybridLogインスタンスとして実装されるが、
stable region（ディスク）へのflushは行わない。
ページ状態はMutable → ReadOnly → Evictedの遷移のみで、
Flushing/Cleanを経由しない。eviction時にはページ内のread cacheレコードの
hash chain再接続処理が必要（F2 Section 7と同様）。

### 2.7 Compaction

F2のlookup-based compactionをシングルスレッド向けに簡略化して実装する。

**Hot-Cold Compaction:** F2の設計を準用する。hot logのBEGIN付近のレコードをcold log tailに移す。
hot logのディスクサイズが設定されたbudgetを超えた時点でトリガーされる。

**Cold-Cold Compaction:** F2の設計を準用する。cold log内の古いnon-liveレコードを回収する。
cold logのディスクサイズが設定されたbudgetを超えた時点でトリガーされる。

liveness判定は、レコードのキーでindex lookupを行い、最新レコードかどうかを確認するだけで完結する。
シングルスレッドのため、F2のConditional-Insert（CI）プリミティブのCAS部分は不要である。

**tombstoneの処理:** F2と同様に、tombstoneレコードもcompactionのliveness判定対象となる。
tombstoneより新しいレコードが存在しなければlive（tombstoneとしてtarget logにコピー）、
存在すればnon-live（物理削除）。cold logに到達したtombstoneは
cold-cold compactionで最終的に物理削除される。

compactionはイベントループの合間に少しずつ進め、ユーザーリクエストのレイテンシへの影響を最小化する。
compaction用の操作バジェット（同時in-flight数）を設け、compaction専用のキュー
（compaction operation queue）で管理する。ユーザー操作を優先し、
compactionのI/Oバジェットを制限することでqueue depthの公平な共有を実現する。

---

## 3. 非同期操作のステートマシン

全操作をio_uringベースのイベントループ上でステートマシンとして駆動する。
I/O待ちで中断・CQE返却で再開する形で、複数の操作が同時にin-flightとなる。

### 3.1 Read

```
ReadStart
  ├─ hot log mutable/read-only → メモリから読んで完了
  ├─ hot log stable (disk) → IO発行 → CQE返却 → キー比較
  │    ├─ 一致 → 完了（read cache挿入判断）
  │    ├─ 不一致 → chain次へ（再度I/Oの可能性）
  │    └─ chain終端 → cold log検索へ
  └─ cold log検索
       ├─ IO_READ_COLD_INDEX: hash chunk読み出し
       └─ IO_READ_COLD_LOG: レコード読み出し → キー比較 → 完了 or NOT_FOUND
```

### 3.2 RMW (Read-Modify-Write)

RMWが唯一の更新操作であり、メタデータ更新とチャンクDmaChunk取得の両方を包含する。

```
RmwStart
  ├─ hot log mutable → in-place update → chunk処理へ
  ├─ hot log read-only → CopyUpdate → RCUでtail書き込み → chunk処理へ
  ├─ hot log stable → IO発行 → CopyUpdate → RCUでtail書き込み → chunk処理へ
  ├─ hot logに無し → cold log検索
  │    → 見つかった → UpdateValue → RCUでtail書き込み → chunk処理へ
  │    → 見つからない → InitialValue → tail書き込み
  │         → Secondary HybridLog更新（hash値append） → chunk処理へ
  │
  chunk処理:
  ├─ chunk_range無し → 完了
  ├─ chunk_range有り、現extentに収まる
  │    → BlockCacheでブロック確保 → キャッシュミスならIO → DmaChunk返却 → 完了
  └─ chunk_range有り、extent拡張必要
       → ExtentAllocator.try_alloc → 確保できなければdisk_extent_queue待ち
       → 旧extent全体コピー（IO発行） → 旧extent解放（snapshot時はCoW保護）
       → BlockCacheでブロック確保 → DmaChunk返却 → 完了
```

全てのケースでレコードのversion番号を確認し、snapshot対応（snap_diff記録 + RCU + extent CoW）を行う。
I/O発行前にindex entryのアドレスを保存し、CQE返却後にindex entryが変わっていないか確認。変わっていたらリトライ。

### 3.3 Delete

```
DeleteStart
  ├─ hot log tailにtombstoneレコード挿入
  ├─ hot-log index更新
  ├─ read cache無効化（該当キー）
  ├─ Secondary HybridLog更新（dirnameレコードのRMW、hash値tombstone化）
  │    → Secondary recordがmutable → in-place → 完了
  │    → Secondary recordがread-only/stable → RCU（IO発行の可能性）
  └─ 完了
```

cold logにレコードが残る可能性があるため、tombstoneは常に挿入する。
Secondary HybridLog更新はKVS内部で自動的に行われる。

### 3.4 I/O Coalescing（待ち合わせHash Table）

複数の同時in-flight操作が同じディスクブロックを読む場合の重複I/Oを排除する。

block addressをキーとする待ち合わせhash tableを用いる。

```
レコード読み出し時:
  ├─ block address計算 → hash table検索
  ├─ in-flight I/Oあり → waiterリストに追加 → WAITING_COALESCED状態
  └─ in-flight I/Oなし → hash tableに登録 → io_uring SQE発行 → WAITING_IO状態

CQE返却時:
  → 全waiter + 発行者のステートマシンを次状態に進める
  → hash tableからエントリ削除
```

- hash計算コストはディスクI/O 1回と比べて無視できる
- テーブルサイズはio_uringのqueue depth（in-flight I/O数上限）で決まり、小さな固定テーブルで十分
- Direct I/Oのアライン済みバッファはプールから確保し、CQE処理完了後に返却する

---

## 4. Blob Extent統合

### 4.1 概要

ファイルデータのチャンクをextent allocatorで管理し、HybridLogレコードにextent参照を持たせる。

```
HybridLogレコード: [key | metadata | extent_addr | extent_length | version]
ChunkStore:         [4KiB-aligned blocks on disk, extent allocator管理]
```

- チャンクサイズ: 4KiB単位の任意長（上限付き）
- Partial Upsert: byte単位の部分更新をサポートする

### 4.2 チャンクアクセスとDirect I/Oの制約

Direct I/Oは4KiB単位のread/writeを要求する。
チャンクへのbyte単位の部分書き込みは、DmaChunkインターフェースを通じて行われる。

DmaChunk acquire時、要求範囲を含むブロックがキャッシュにない場合、
KVS内部でディスクからの読み出しが発生する。
ユーザーはDmaChunkで返されたメモリ領域に直接書き込み、dropで完了を通知する。
実際のディスクへの書き戻しはLRUキャッシュのwriteback機構に委ねられる。

### 4.3 Extent Put操作

extentの更新操作には2つのパターンがある。

**カバーするPut:** 新しいデータが現在のextent範囲を完全にカバーする場合、
旧extentを破棄して新規extentを割り当てる。

**カバーしないPut（Partial Update）:** 現在のextentの一部を更新する場合、
Read-Modify-Write操作を用いる。ディスクから既存データを読み出し、
部分更新を適用して書き戻す。

### 4.4 LRUブロックキャッシュ

ブロック単位のLRUキャッシュにより、連続的なpartial upsertを吸収する。

```
PartialUpsert:
  ├─ キャッシュヒット → メモリ上でbyte範囲書き換え → 完了（高速）
  └─ キャッシュミス → ディスクからブロック読み → キャッシュに載せて書き換え

バックグラウンドWriteback:
  dirty比率 or タイマー → dirtyブロックをio_uringでディスクに書き戻し
```

- hotなチャンクへの連続writeはキャッシュ上で吸収され、最終的に1回のwriteで永続化される
- Readもキャッシュを通すことで、dirtyデータの最新値を返せる
- 待ち合わせhash tableとの併用で、同一ブロックへの並行I/Oも排除される

### 4.5 DmaChunkインターフェース

ゼロコピー書き込みを実現するため、ユーザーに直接書き込み可能なメモリ領域を
貸し出すDmaChunkインターフェースを提供する。
RDMA WRITEやDirect I/Oによる直接書き込みに対応する。

**Version意味論:**

DmaChunkのacquire時点で論理的に書き込みが確定し、versionが帰属する。
dropは物理的な完了通知であり、実際の書き込みタイミングは意味論に影響しない。

```
acquire = 論理的な書き込み開始（version帰属が確定）
drop    = 物理的な完了通知（dirtyマーク）
```

mark_snapshot前にacquireされたDmaChunkは、mark_snapshot後にdropされても
version_nに属する遅延書き込みとして扱われる。
version_n+1のrmwが同じキーに来た場合、extent CoWにより新extentが確保されるため、
旧extent（DmaChunkが書き込み中の可能性がある）は汚されない。

これにより、DmaChunkにversion tagやlive追跡などの特別な管理は不要となる。

**Rust APIインターフェース:**

```rust
/// ジョブ識別子
struct JobId(u64);

/// 操作の即時結果
enum OpResult<T> {
    EagerOk(T),
    EagerErr(Error),
    Asynchronous(JobId),
}

/// 完了通知
enum CompletionValue {
    Read(ReadResult),
    Rmw(RmwResult),
    Unit,
    Dir(Vec<Attr>),
    Scan(Option<ScanEntry>),  // scan_nextの結果（Noneでスキャン完了）
}

struct Completion {
    job_id: JobId,
    result: Result<CompletionValue, Error>,
}

/// Primary HybridLogのキー
struct Key {
    dirname: PathComponent,  // 最大4KiB (POSIX準拠)
    filename: PathComponent,
}

/// Secondary HybridLogのキー（ディレクトリ列挙用）
struct Prefix {
    dirname: PathComponent,
}

/// ユーザー定義のメタデータ型（アプリケーション固有）
type Attr = /* application-defined fixed-size metadata */;

/// 読み出し対象
enum ReadTarget {
    /// メタデータ（Attr）のみ
    AttrOnly,
    /// チャンクデータのみ
    ChunkOnly(Range<u64>),
    /// 両方
    Both(Range<u64>),
}

/// 読み出し結果（extent情報等の内部データは含まない）
struct ReadResult {
    attr: Option<Attr>,          // AttrOnly or Both時
    chunk: Option<DmaChunk>,     // ChunkOnly or Both時
}

struct RmwResult {
    chunk: Option<DmaChunk>,  // chunk_range指定時のみ
}

/// DmaChunk: BlockCache上のエントリへの参照（値型、ヒープ確保不要）
/// BlockCacheへの生ポインタを保持し、Clone/Dropで直接ref_countを増減する。
/// プロセス生存期間中はBlockCacheのアドレスが不変であるため安全。
struct DmaChunk {
    cache: *mut BlockCache,
    cache_entry_idx: usize,
    buffer_ptr: *mut u8,
    offset: u32,
    length: u32,
}
// Clone: inc_ref, Drop: dec_ref（詳細はSection 8.10参照）

/// RMWのユーザー定義ロジック
/// KVS作成時にこのtraitを実装した構造体を渡す。
trait RmwCallbacks {
    /// アプリケーション固有のRMW入力型
    type Input;

    /// キーが存在しない場合の初期値生成
    fn initial_value(&self, key: &Key, input: &Self::Input) -> Attr;
    /// 既存値の更新（in-place更新 or CopyUpdate共通）
    fn update_value(&self, key: &Key, input: &Self::Input, old: &Attr) -> Attr;
    /// チャンクのDmaChunkが必要かどうか、必要なら範囲を返す
    fn chunk_range(&self, input: &Self::Input) -> Option<Range<u64>>;
}

impl<C: RmwCallbacks> Kvs<C> {
    /// 読み出し（Attrのみ / チャンクのみ / 両方）
    fn read(&mut self, key: &Key, target: ReadTarget) -> OpResult<ReadResult>;

    /// Read-Modify-Write（唯一の更新操作）
    fn rmw(&mut self, key: &Key, input: C::Input) -> OpResult<RmwResult>;

    /// 削除（Primary tombstone + Secondary hash配列tombstone化を自動で行う）
    fn delete(&mut self, key: &Key) -> OpResult<()>;

    /// ディレクトリ列挙（Attrのみ返却）
    fn readdir(&mut self, prefix: &Prefix) -> OpResult<Vec<Attr>>;

    /// Snapshot（複数snapshotの同時存在をサポート）
    fn mark_snapshot(&mut self) -> SnapshotId;
    fn snapshot_complete(&mut self, id: SnapshotId);

    /// Snapshot version時点のpoint read
    fn read_snapshot(&mut self, key: &Key, id: SnapshotId, target: ReadTarget)
        -> OpResult<ReadResult>;

    /// Snapshot stage-out用スキャン（pull型）
    fn scan_snapshot_start(&mut self, id: SnapshotId) -> ScanId;
    fn scan_next(&mut self, scan_id: ScanId) -> OpResult<Option<ScanEntry>>;
    fn scan_drop(&mut self, scan_id: ScanId);

    /// io_uringのCQEを回収し、完了したジョブを返す
    fn poll(&mut self, completions: &mut Vec<Completion>);
}
```

rmwが唯一の更新操作であり、以下の全てを包含する。

- ファイルcreate: initial_value callback + chunk確保
- stat更新: update_value callback（chunk_range返さない）
- ファイルwrite: update_value callback + chunk_range
- extent拡張: chunk_rangeが現extentを超える場合に自動実行

**Secondary Index自動メンテナンス:**

KVSはrmw/delete時にSecondary HybridLogの更新を自動的に行う。

- rmwでキーが新規作成された場合（initial_value経由）:
  dirnameのSecondary recordにhash(dirname, filename)をappend
- deleteの場合:
  dirnameのSecondary recordの該当hash値をtombstone化（ゼロ埋め）

ユーザーはSecondary Indexの存在を意識する必要がない。

**acquire処理（rmw内部）:**

```
rmw(key, input):
  1. Primary HybridLog lookupでレコード取得（hash chain traversal）
  2. version確認（snapshot対応、必要ならsnap_diff記録）
  3. レコードが見つかった場合:
     callbacks.update_value(key, input, old_attr) → new_attr
     レコードが見つからなかった場合:
     callbacks.initial_value(key, input) → new_attr
     → Secondary HybridLog更新（hash値append）
  4. レコード書き込み:
     Mutable region → in-place更新
     Read-Only/Stable/Cold → RCU（Section 9.1参照）
     snapshot対応時 → extent CoW
  5. callbacks.chunk_range(input)がSome(range)の場合:
     要求範囲が現extentに収まる → BlockCacheでブロック確保 → DmaChunk返却
     収まらない → extent拡張（新規確保 + 旧extent全体コピー） → DmaChunk返却
```

**drop時の処理:**

```
drop(DmaChunk):
  → BlockCache.dec_ref(cache_entry_idx)（即座に実行、pollを待たない）
  → ref_count == 0 → status = Dirty
  → LRUキャッシュのwriteback管理に委ねる
```

writebackは純粋なキャッシュeviction最適化であり、snapshotの正しさとは無関係である。
stage-outがversion_nのextentを読む際は、キャッシュ上にdirtyデータがあればそこから読み、
なければディスクから読む。

**並行アクセスの意味論:**

同一範囲への複数のDmaChunkが同時にliveであることを許容する。
同一範囲への並行書き込みの結果は未定義とし、これはPOSIXのpwriteの意味論と一致する。
KVS側でのDmaChunkの排他管理やlive追跡は行わない。

**extent拡張の安全性:**

extent拡張はメタデータ更新（extent_addr, extent_length）を伴うが、
シングルスレッドのためacquire処理中に別のacquireが割り込むのは
I/O待ち（非同期read）の時のみである。
メタデータ更新自体はメモリ上の操作であり一瞬で完了するため、
拡張操作のatomicity は自然に保たれる。

---

## 5. Snapshot機構

### 5.1 目的

PFS（並列ファイルシステム）への非同期stage-outを実現するため、
ある時点の一貫したスナップショットを提供する。
stage-out中もアプリケーションのwrite操作を止めずに受け付ける。
複数のsnapshotを同時にactiveにすることが可能である。

ad-hocファイルシステムの特性上、常時のcrash safetyは要求せず、
明示的なsync（snapshot）発行時にのみバージョンの永続化を行う。

### 5.2 Snapshot管理構造

```rust
struct SnapshotManager {
    /// 現在のglobal version（単調増加、mark_snapshotごとにインクリメント）
    current_version: u32,
    /// activeなsnapshotのリスト
    active_snapshots: Vec<SnapshotState>,
}

struct SnapshotState {
    id: SnapshotId,
    version: u32,
    snapshot_tail: u64,            // mark_snapshot時のHybridLog tail offset
    snap_diff: HashMap<u64, u64>,  // key_hash → version時点のrecord address
    snap_min_address: u64,         // snap_diff内の最小record address
}
```

### 5.3 mark_snapshot操作

`mark_snapshot` は即座に完了する軽量な境界操作である。

```
mark_snapshot():
  // version インクリメント
  current_version += 1
  version_n = current_version - 1  // snapshotされるversion

  // HybridLog
  snapshot_tail = hybridlog.tail_offset
  hybridlog.read_only_offset = hybridlog.tail_offset  // 全レコードをimmutableに

  // Snapshot State作成
  active_snapshots.push(SnapshotState {
      version: version_n,
      snapshot_tail,
      snap_diff: 空,
      snap_min_address: MAX,
  })

  // ChunkStore
  全dirtyチャンクをlazy writeback queueに投入

  return SnapshotId
```

**HybridLog側:** read-only offsetをtailまで進めることで、version_nの全レコードが
immutableになる。以降の更新はRCUにより新レコードとしてtailに追記される。
version_nのレコード実体はログ上から消えない。

**ChunkStore側:** dirtyチャンクをwritebackキューに入れる。
これらのチャンクはCoWにより保護されるため、安全にwritebackできる。

### 5.4 Snapshot Index Table (snap_diff)

RMWが発行された際、旧レコードのversionを確認し、
そのversionをカバーする全activeなsnapshotのsnap_diffに旧値を記録する。

```
RMW時のsnap_diff更新:
  old_record = 更新対象の旧レコード
  for each active snapshot_i:
    if old_record.version <= snapshot_i.version:
      // このsnapshotにとってold_recordがsnapshot時点の値
      if snap_diff_i にこのkey_hashがまだない:
        snap_diff_i[key_hash] = old_record.address
        snap_min_address_i = min(snap_min_address_i, old_record.address)
  RCUでtailに新レコード追記、index更新
```

各snap_diffに対して、あるキーについて最初の更新時にのみ旧値を記録する。
既に記録済みならスキップ。containsチェック + 条件付きinsertでO(1)。
activeなsnapshot数は通常1-2個であり、全snapshot走査のコストは無視できる。

### 5.5 ChunkStoreのSnapshot対応

チャンクが更新される場合、レコードのversion番号で判断する。

```
Chunk更新時:
  いずれかのactive snapshotがこのレコードのversionをカバーしている →
    新規extentを割り当て（CoW）
    旧extentはsnapshot用に保持（snap_diffの対応エントリに含まれる）
  どのsnapshotにもカバーされていない →
    通常通りin-place更新
```

### 5.6 Snapshot Stage-Out API

stage-outプロセスがsnapshot version_nの全データを列挙してPFSに送出するための
pull型スキャンAPIを提供する。

**API:**

```rust
/// スキャン結果のエントリ
struct ScanEntry {
    key: Key,
    attr: Attr,
    /// チャンクデータへのDmaChunk（extent未割り当てならNone）
    chunk: Option<DmaChunk>,
}

impl<C: RmwCallbacks> Kvs<C> {
    /// Snapshot stage-out用のスキャンセッションを開始
    fn scan_snapshot_start(&mut self, id: SnapshotId) -> ScanId;

    /// 次のエントリを取得（非同期I/Oの可能性あり）
    /// Noneが返ったらスキャン完了
    fn scan_next(&mut self, scan_id: ScanId) -> OpResult<Option<ScanEntry>>;

    /// スキャンセッションを終了（途中中断も可能）
    fn scan_drop(&mut self, scan_id: ScanId);
}
```

pull型によりstage-out側がPFSへの送信ペースに合わせてscan_nextを呼べる。
backpressure制御が自然に実現される。

**スキャンの内部アルゴリズム:**

スキャンは2フェーズで構成される。

```
Phase 1: snap_diffのエントリを列挙（snapshot以降に更新されたキー）
  snap_diff_iの各(key_hash, old_addr)について:
    record = read(old_addr)  // 非同期I/Oの可能性
    if not tombstone:
      yield ScanEntry { key, attr, chunk }
    emitted_keys.insert(key_hash)

Phase 2: hash index走査（snapshot以降に変更されていないキー）
  hot_log_index + cold_log_indexの全バケットを順次走査:
    for each entry:
      if emitted_keys.contains(entry.key_hash):
        skip  // Phase 1で出力済み
      record = read(entry.address)  // 非同期I/Oの可能性
      if not tombstone:
        yield ScanEntry { key, attr, chunk }
```

**ステートマシン:**

```rust
struct ScanState {
    snapshot_id: SnapshotId,
    phase: ScanPhase,
    emitted_keys: HashSet<u64>,
}

enum ScanPhase {
    /// snap_diffイテレータの現在位置
    DiffScan { diff_iter_pos: usize },
    /// hash index走査の現在位置（bucket index）
    IndexScan { bucket_pos: usize },
    /// 完了
    Done,
}
```

scan_nextの呼び出しごとに1エントリ分だけ進む。
レコード読み出しでディスクI/Oが必要な場合はOpResult::Asynchronousを返し、
I/O完了後の次のpollでcompletionsに結果が返る。
index走査自体はメモリ上の操作でI/O不要だが、
レコード本体の読み出しでI/Oが発生しうる。

**Version指定Point Read:**

スキャンとは別に、特定キーのversion_n時点の値をpoint readする機能も提供する。

```
read_snapshot(key, snapshot_id):
  snapshot_i = active_snapshots[snapshot_id]
  snap_diff_iにkeyのエントリがあるか確認
  ├─ ある → snap_diff_iの旧アドレスからレコードを読む（version_n時点の値）
  └─ ない → 現在のindex entryから読む（snapshot以降変更されていない）
```

### 5.7 Compaction との整合性

snapshot有効時のcompactionでは、全activeなsnap_diffを確認する。

```
Compaction with Snapshots [BEGIN, UNTIL]:
  for each record R in [BEGIN, UNTIL]:
    index lookupでliveness判定

    live → target_logにコピー、index更新

    non-live →
      いずれかのactive snap_diff_iがRを参照しているか確認:
        for each active snapshot_i:
          if snap_diff_i の値（旧アドレス）== R.address:
            → Rは保護、スキップ（R自体もextentも保護）
            → break
      どのsnapshotにも保護されていない → スキップ + extent解放
```

**truncation制約:** 全activeなsnap_min_addressの最小値でtruncationが制限される。

```
truncation時:
  global_min = min(snapshot_i.snap_min_address for all active snapshot_i)
  UNTIL > global_min → global_minまでしかtruncate不可
  UNTIL <= global_min → 通常通りtruncate可能
```

### 5.8 Snapshot完了時の処理

stage-outが完了したらsnapshotを破棄する。
extent解放時には他のactiveなsnapshotが同じレコードを参照していないか確認する。

```
snapshot_complete(snapshot_id):
  snapshot_i = active_snapshots[snapshot_id]

  for each (key_hash, old_address) in snap_diff_i:
    old_record = read(old_address)
    old_extent_addr = old_record.extent_addr
    current_extent_addr = 現在のindexから取得したレコードのextent_addr

    // extent解放判定
    if old_extent_addr != current_extent_addr:
      // 他のactiveなsnapshotが同じレコードを保護していないか確認
      protected = false
      for each other active snapshot_j (j != i):
        if snap_diff_j の値 == old_address:
          protected = true
          break
      if not protected:
        extent_allocator.free(old_extent_addr)

  active_snapshots.remove(snapshot_id)
```

snapshot完了後、次のcompactionでsnapshotにより保護されていた旧レコードが
自然に回収される。

### 5.9 安全性

シングルスレッド + イベントループにおいて、以下の操作は全てイベントループ内で
直列に実行されるため、snap_diffの一貫性は常に保たれる。

- snap_diffへの追加: RMW時のみ（全active snapshotに対して）
- snap_diffの確認: compactionのnon-liveレコード判定時 / version指定Read時
- snap_diffの破棄: snapshot完了時のみ

async I/Oにより操作が中断・再開されても、各操作の「中間状態」でyieldする際に
snap_diffの不整合は発生しない。

activeなsnapshot数が多いとRMW時のsnap_diff更新コストが線形に増加するが、
実用上activeなsnapshot数は1-2個（前回のstage-outと現在のstage-out）であり、
性能への影響は無視できる。

---

## 6. Secondary Index（ディレクトリ列挙用）

### 6.1 目的

`readdir` 操作（dirname配下の全ファイル列挙）を効率的に実現するため、
Primary HybridLogとは独立したSecondary Indexを導入する。

readdirはHPCワークロードにおいて支配的な操作ではないため、
read性能よりも write性能とcompactionとの独立性を優先した設計とする。

### 6.2 構造

Secondary Indexは、dirname をキーとした専用のHybridLogインスタンスとして実装する。

```
Secondary HybridLog:
  key   = dirname
  value = [hash_1, hash_2, ..., hash_N]
          ※ hash_i = (dirname, filename_i) のhash値
```

filenameの実体はSecondary Index側に持たず、hash値のみを格納する。
hash値が8バイトの場合、1000ファイルのディレクトリで約8KBのレコードサイズとなる。

Secondary IndexはPrimary HybridLogのhash indexへの候補キー供給源として機能する。
hash衝突によるfalse-positiveはPrimary側でのキー比較により除外される。
false-negative（ディレクトリ内のファイルが欠落する）は許容しない。

### 6.3 操作

**ファイル作成（create）:**

```
create(dirname, filename):
  1. Primary HybridLog: レコード挿入
  2. Secondary HybridLog: dirnameレコードをRMW、hash(dirname, filename)をappend
```

**ファイル削除（delete）:**

```
delete(dirname, filename):
  1. Primary HybridLog: tombstone挿入
  2. Secondary HybridLog: dirnameレコードをRMW、該当hash値をtombstone化（ゼロ埋め）
```

削除時はhash配列内のエントリをゼロ埋め（tombstone）するだけで、
配列の詰め直しは行わない。シンプルで高速な操作となる。

**ディレクトリ列挙（readdir）:**

```
readdir(dirname):
  1. Secondary HybridLog: dirnameレコードを読み出し → hash配列取得
  2. tombstone（ゼロ値）をスキップしつつ各hash値でPrimary hash index lookup
  3. Primary HybridLogからメタデータを読み出して返却
```

readdirの結果として stat 情報を返すのが一般的であり、
Primary HybridLogへのlookupは本質的に必要なコストである。
Secondary Indexがhash値のみを保持することによる追加コストはない。

### 6.4 Compactionとの独立性

Secondary HybridLogはPrimary HybridLogとは完全に独立したHybridLogインスタンスであり、
それぞれのcompactionは互いに影響しない。

Secondary HybridLogのcompaction時には、レコードをtarget logにコピーする際に
hash配列内のtombstoneエントリを除去して詰め直した配列を書き込む。
これによりtombstoneの蓄積が自然に解消される。

```
Secondary Compaction:
  レコードコピー時:
    旧hash配列からtombstone（ゼロ値）を除去
    詰め直した配列を新レコードとして書き込み
```

特別なrebuildフェーズは不要であり、通常のcompaction処理の延長として実現される。

### 6.5 HybridLog機構の再利用

Secondary HybridLogはPrimary HybridLogと同じエンジンコードのインスタンスとして動作する。

- Mutable regionでのin-place更新（hash値の追加・tombstone化）
- Read-only/stable regionではRCUでtail追記
- Compaction: 同じlookup-basedアルゴリズム（+ tombstone除去）
- Snapshot: Primary側と同じ方式（immutable化 + snap_diff）がそのまま適用可能

実装の追加コストが最小限に抑えられる。

### 6.6 設計上の考慮事項

**RMW頻度:** ファイルcreate/deleteのたびにdirnameレコードをRMWする。
同一ディレクトリへの大量createが集中する場合（mdtest-hard等）、
同じレコードへのRMWが頻発するが、mutable region内であればin-place更新で高速に処理される。

**レコードサイズの成長と倍-倍確保:** ディレクトリ内のファイル数増加に伴いhash配列が拡大する。
hash配列の領域は倍-倍（doubling）で確保する。
現在の配列容量が不足した場合、2倍のサイズのhash配列を持つ新レコードをRCUでtailに追記する。
これによりcreate時のin-place append（配列末尾追加）が大部分のケースで成功し、
RCUフォールバックは配列拡張時のみに限定される。

**tombstoneの蓄積:** 削除が多いディレクトリではhash配列内にtombstoneが蓄積し、
readdir時のスキャンコストが増加する。compactionにより自然に解消されるが、
compaction間隔が長い場合は一時的にreaddir性能が劣化しうる。
readdirが支配的ワークロードではないため、これは許容範囲とする。

---

## 7. 内部アーキテクチャ: バッファ管理と操作パイプライン

### 7.1 概要

全ての操作はステートマシンとしてイベントループ上で駆動される。
操作の任意の時点で「リソース待ち」が発生しうるが、全てのリソース枯渇を
同じ中断・再開メカニズムで統一的に処理する。
全操作を償却O(1)で非同期に達成する。

**統一的な中断モデル:**

操作の実行中、リソースが必要になった時点で確保を試みる。
取得できなければステートマシンの状態を保持したまま対応するキューに中断し、
リソースが利用可能になったら中断した地点から再開する。

```rust
/// ステートマシンの中断理由
enum SuspendReason {
    /// page buffer poolに空きがない
    WaitingPageBuffer,
    /// chunk buffer poolに空きがない
    WaitingChunkBuffer,
    /// ディスクextent容量不足、extent確保待ち
    WaitingDiskExtent,
    /// io_uring CQE待ち
    WaitingIo,
    /// 他の操作のI/Oに相乗り中
    WaitingCoalesced,
}
```

### 7.2 6つのキュー

システム全体で6つのキューを管理する。全てのリソース待ちはこれらのキューのいずれかに
ステートマシン状態ごと格納され、poll時にリソースが利用可能になったら再開される。

```rust
struct OperationQueues {
    // === I/O Coalescingキュー ===
    /// HybridLog page単位のI/O待ち合わせ
    page_coalescing: PageCoalescingTable,
    /// Extent block単位のI/O待ち合わせ
    chunk_coalescing: ChunkCoalescingTable,

    // === バッファ確保待ちキュー ===
    /// HybridLog page buffer確保待ち
    page_buffer_queue: VecDeque<SuspendedOp>,
    /// Extent chunk buffer確保待ち
    chunk_buffer_queue: VecDeque<SuspendedOp>,

    // === ディスク容量待ちキュー ===
    /// Extent allocatorのディスク容量確保待ち
    disk_extent_queue: VecDeque<SuspendedOp>,

    // === Compactionバジェットキュー ===
    /// Compaction操作のI/Oバジェット待ち
    compaction_queue: VecDeque<SuspendedOp>,
}

struct SuspendedOp {
    job_id: JobId,
    /// 中断時点のステートマシン状態（途中結果を含む）
    state_machine: OpStateMachine,
}
```

**Page Coalescing Queue:** HybridLog page単位でディスクI/Oを待ち合わせる。
同じpageへの複数の読み出し要求を1回のI/Oに集約する。

**Chunk Coalescing Queue:** Extent block（4KiB）単位でディスクI/Oを待ち合わせる。
同じblockへの複数の読み出し要求を1回のI/Oに集約する。

**Page Buffer Queue:** HybridLog page buffer poolの空き待ち。
LRU evictionでも空きが作れない場合（全bufferがpinまたはin-flight I/O中）にここに入る。

**Chunk Buffer Queue:** Extent chunk buffer poolの空き待ち。
Page Buffer Queueと同様だが、chunk用のバッファプール側の枯渇に対応する。

**Disk Extent Queue:** extent allocatorでのディスク容量確保待ち。
write操作でextentの新規確保や拡張が必要だがディスク空き領域が不足している場合にここに入る。
compactionやdeleteによるextent解放で空きが生じた時に再開される。

**Compaction Queue:** compaction操作のI/Oバジェット待ち。
compactionが使用するin-flight I/O数をカウントし、設定されたバジェット上限を超えた場合に
compaction操作をここに入れる。ユーザー操作のI/Oを優先し、
compactionがio_uring queue depthを独占しないよう制御する。

### 7.3 バッファアロケータ

extent用バッファとHybridLog page用バッファはそれぞれ独立したプールで管理する。
`try_alloc` は `Option<BufferHandle>` を返し、`None` の場合はバッファが不足していることを示す。

```rust
/// try_allocで確保、Noneなら空きがない
trait BufferAllocator {
    fn try_alloc(&mut self) -> Option<BufferHandle>;
    fn free(&mut self, handle: BufferHandle);
}

/// HybridLogのpage用（mutable region, read cache等）
struct PageBufferPool { /* 固定サイズページフレームのプール */ }

/// Extent block用（4KiBアライン、DmaChunk用）
struct ChunkBufferPool { /* Direct I/O用アライン済みバッファのプール */ }

/// Extent allocator（ディスク上の領域管理）
/// Bitmap方式でインメモリ管理。ディスク上への永続化は行わず、
/// 復元はHybridLog（hot + cold）を全走査してliveレコードの
/// extent_addr/extent_lengthから再構築する。
struct ExtentAllocator {
    /// 4KiBブロック単位のbitmap（1 = 使用中, 0 = フリー）
    /// 例: 100GBのextent領域 → 約26Mブロック → 約3.2MiBのbitmap
    bitmap: Vec<u64>,
    /// next-fit方式: 最後に割り当てた位置から先にスキャン
    next_scan_pos: usize,
    /// 総ブロック数
    total_blocks: usize,
    /// フリーブロック数（高速な容量確認用）
    free_blocks: usize,

    fn try_alloc(&mut self, block_count: u32) -> Option<ExtentHandle>;
    fn free(&mut self, handle: ExtentHandle);
}
```

`try_alloc` が `None` を返すケース:

- **PageBufferPool / ChunkBufferPool:** キャッシュの全バッファが使用中でevict不可の場合。
  通常はLRU evictionにより空きが作られる。
- **ExtentAllocator:** ディスク上に要求サイズの連続フリーブロックが存在しない場合。
  compactionやdeleteによるextent解放で解消される。

**ExtentAllocatorの割り当て戦略:**

```
try_alloc(block_count):
  next_scan_posからbitmapをスキャン
  block_count個の連続する0 bitを探す
  → 見つかった: 該当bitを1に設定、free_blocks更新、ExtentHandle返却
  → 全体を一周しても見つからない: None
```

next-fit方式によりスキャン開始位置を前回の割り当て位置から進めることで、
フラグメンテーションを軽減し、平均的なスキャン距離を短縮する。

**復元処理:**

```
recover():
  bitmap = 全bitを0に初期化
  for each live record in HybridLog (hot + cold):
    if record.extent_addr != INVALID:
      bitmapの該当範囲を1にマーク
  free_blocks = 0 bitの総数
  next_scan_pos = 0
```

**HybridLog pageバッファ:** HybridLogのcircular buffer内のページフレーム。
mutable region、read-only region、read cacheのページを管理する。
ページサイズはHybridLogの設定に依存する。

**Chunk blockバッファ:** extent dataの読み書きに使用する4KiBアライン済みバッファ。
LRUブロックキャッシュの実体でもあり、DmaChunkのバッキングメモリとなる。

### 7.4 Chunk Cache Eviction制御

chunk blockバッファはLRU/CLOCKベースのキャッシュとして機能する。
各blockは以下の状態を持ち、evict可能かどうかが厳密に決まる。

```
block状態:
  Free    → 未使用。確保可能。
  Clean   → ディスクと同じ内容。evict可能（即座にFree化）。
  Dirty   → メモリ上にのみ変更がある。evict不可。
              writebackが完了するまでデータの唯一のコピーはメモリ上。
  Pinned  → writeback I/O中。evict不可。I/O完了でCleanに遷移。
  Stale   → extent CoWや上書きで不要になった。即座にFree化可能。
```

**evictできるのはCleanとStaleのみ。** Dirtyはデータの唯一のコピーが
メモリ上にしかないため、書き戻しが完了するまで絶対にevictできない。
DmaChunkのlive/drop状態は無関係であり、
ディスクに書き戻されたかどうかだけが状態遷移を決定する。

**バッファ確保のフロー:**

```
try_alloc():
  1. Freeがあれば返す
  2. StaleがあればFree化して返す
  3. CleanがあればLRU/CLOCK順でevict → Free化して返す
  4. いずれもない → None（Dirtyの書き戻し完了待ち）
```

**適応的writeback制御:**

通常時はwritebackを急がず、キャッシュヒット率を優先してDirtyのまま保持する。
バッファ確保待ちキュー（chunk_buffer_queue）の圧力に応じて
writeback頻度を動的に調整する。

```
poll内のwriteback制御:
  pending_demand = chunk_buffer_queue.len()
  available = free_count + clean_count + stale_count

  // Staleは即座にFree化
  reclaim_stale_blocks()

  if available < pending_demand:
    // Dirtyのwritebackを進めてCleanを増やす
    writeback_budget = min(
      pending_demand - available,
      max_inflight_writeback - inflight_writeback
    )
    for _ in 0..writeback_budget:
      LRU/CLOCK順でDirtyを選択 → writeback SQE発行 → Pinned状態に

  // Pinned → I/O完了(CQE) → Clean → 次のpollでevict可能
```

writeback I/O中のblockはPinned状態でevictできないため、
writeback concurrencyには上限（max_inflight_writeback）を設ける。
過剰なwriteback発行はかえってevict可能blockを減らす。

writeback完了(CQE返却)でblockがCleanになり、
次のpollでevict → Free → バッファ確保待ち解消、
という流れで最低1 poll分のレイテンシが発生するが、
通常はStaleやCleanの在庫で即座に確保できるため影響は限定的である。

### 7.5 Coalescingテーブル

HybridLog page単位とextent block単位の2つの待ち合わせテーブルを持つ。
バッファプールとI/Oのアラインメントが異なるため分離する。

```rust
struct CoalescingTable {
    table: HashMap<u64, CoalescingEntry>,
}

struct CoalescingEntry {
    buffer: BufferHandle,          // I/O先のバッファ（確保済み）
    waiters: Vec<SuspendedOp>,     // I/O完了待ちの操作リスト
}
```

I/O発行の流れ:

```
操作がディスク読み出しを必要とする時:
  1. 対象アドレスで該当するcoalescing tableを検索
  2. in-flight I/Oあり → waiterリストに追加（I/O発行しない、WaitingCoalesced）
  3. in-flight I/Oなし → coalescing tableに登録 → io_uring SQE発行（WaitingIo）

CQE返却時:
  1. coalescing tableから該当エントリを取得
  2. 全waiter + 発行者のステートマシンを再開
     → 次のリソース待ちが発生するか、操作完了まで進む
  3. coalescing tableからエントリ削除
```

### 7.6 操作中のリソース確保

操作中にリソースが必要な任意の時点で、統一的に中断・再開が行われる。

```
リソース必要 → try_alloc (buffer / extent)
├─ Some(handle) → 続行
└─ None → SuspendedOp { state_machine: 現在の状態 } を対応キューに追加
          → 初回呼び出し時: OpResult::Asynchronous(job_id) を返却
          → poll中の再開時: 単に中断してpoll再開を待つ

I/O必要 → coalescing table検索
├─ 相乗り可能 → waiterリストに追加（WaitingCoalesced）
└─ 新規I/O → SQE発行（WaitingIo）
```

### 7.7 pollの処理フロー

```rust
fn poll(&mut self, completions: &mut Vec<Completion>) {
    // Step 1: io_uring CQEを回収
    //   → 完了したI/Oのcoalescing entryからwaiterを起こす
    //   → waiterのステートマシンを再開
    //   → 操作完了 → completionsに追加
    //   → 次のI/Oが必要 → 新たなSQE発行
    //   → バッファ/extent不足 → 対応する待ちキューへ
    //   → I/O完了でバッファが解放される可能性あり
    //   → compaction完了でextentが解放される可能性あり
    self.process_cqes(completions);

    // Step 2: page buffer確保待ちキューを処理
    self.process_page_buffer_queue(completions);

    // Step 3: chunk buffer確保待ちキューを処理
    self.process_chunk_buffer_queue(completions);

    // Step 4: disk extent確保待ちキューを処理
    self.process_disk_extent_queue(completions);

    // Step 5: compactionバジェットキューを処理
    //   → compaction in-flight数がバジェット未満なら再開
    self.process_compaction_queue(completions);

    // Step 6: io_uring SQEをsubmit（バッチ発行）
    self.submit_pending_sqes();
}
```

Step 1でI/O完了 → バッファ解放やextent解放が起き、
Step 2-5でそのリソースを待っていた操作が進行できるようになる。
この順序によりリソースのターンアラウンドが最小化される。
ユーザー操作（Step 2-4）がcompaction（Step 5）より先に処理されるため、
ユーザー操作が常に優先される。

ステートマシン再開後、操作が完了せずに別のリソース待ちに入ることもある。
その場合は適切なキューに再度入るだけであり、
poll呼び出しを繰り返すことで全ての操作が最終的に完了する。

### 7.8 償却O(1)の根拠

各操作の各ステップがO(1)で完了する。

| ステップ | 操作 | 計算量 |
|---------|------|--------|
| バッファ確保 | try_alloc / キューpush | O(1) |
| Extent確保 | try_alloc / キューpush | O(1) |
| Coalescing | hash table lookup/insert | O(1) |
| I/O発行 | io_uring SQE submit | O(1) |
| I/O完了 | CQE回収 + waiter通知 | O(1) 平均（waiter数は定数期待） |
| 実操作 | メモリ上の操作 | O(1) |
| 中断/再開 | ステートマシン状態の保存/復元 | O(1) |

poll 1回あたりの処理量はCQE数 + 各待ちキューのリトライ数であり、
全てin-flight操作数に比例する。io_uring queue depthが定数であるため、
poll全体もO(1)で完了する。

---

## 8. モジュール設計

### 8.1 モジュール構成

```
kvs/
├── lib.rs                // Kvs<C> 公開API
├── types.rs              // Key, Prefix, Attr, OpResult, Completion等の型定義
├── engine/
│   ├── mod.rs
│   ├── hybridlog.rs      // HybridLog<R> (全ログ共通)
│   ├── hash_index.rs     // HashIndex (バケット配列 + overflow)
│   ├── record.rs         // Record trait, RecordHeader, PrimaryRecord, SecondaryRecord
│   ├── cold_index.rs     // ColdLogIndex (2-level)
│   └── read_cache.rs     // ReadCache
├── chunk/
│   ├── mod.rs
│   ├── extent_alloc.rs   // Bitmap Extent Allocator
│   ├── cache.rs          // LRU/CLOCK Block Cache + eviction制御
│   └── dma_chunk.rs      // DmaChunk (Rc-based)
├── secondary/
│   ├── mod.rs            // Secondary HybridLog (dirname index)
│   └── hash_array.rs     // hash配列の管理 (append, tombstone, compact)
├── snapshot/
│   ├── mod.rs            // SnapshotManager
│   ├── snap_diff.rs      // snap_diff hash table
│   └── scan.rs           // ScanState, scan_next
├── io/
│   ├── mod.rs
│   ├── ring.rs           // io_uring wrapper
│   ├── coalescing.rs     // CoalescingTable (page/chunk共用)
│   └── buffer_pool.rs    // PageBufferPool, ChunkBufferPool
├── ops/
│   ├── mod.rs            // OpStateMachine, SuspendedOp
│   ├── read.rs           // ReadState ステートマシン
│   ├── rmw.rs            // RmwState ステートマシン
│   ├── delete.rs         // DeleteState ステートマシン
│   ├── readdir.rs        // ReaddirState ステートマシン
│   └── scan.rs           // ScanState ステートマシン
└── compaction/
    ├── mod.rs             // CompactionState ステートマシン
    ├── hot_cold.rs        // Hot-Cold Compaction
    └── cold_cold.rs       // Cold-Cold Compaction
```

### 8.2 Kvs\<C\> 本体構造

スケジューラを独立モジュールとせず、Kvs本体にキュー管理とpollループを統合する。
全操作はenumベースのステートマシンで表現し、リソース待ちキューに中断・再開される。

```rust
struct Kvs<C: RmwCallbacks> {
    // === Primary Storage ===
    hot_log: HybridLog<PrimaryRecord>,
    cold_log: HybridLog<PrimaryRecord>,
    hot_index: HashIndex,
    cold_index: ColdLogIndex,
    read_cache: ReadCache,

    // === Secondary Storage ===
    secondary_log: HybridLog<SecondaryRecord>,
    secondary_index: HashIndex,

    // === Chunk Storage ===
    chunk_store: ChunkStore,

    // === Snapshot ===
    snapshot_mgr: SnapshotManager,

    // === IO ===
    ring: IoUring,
    page_coalescing: CoalescingTable,
    chunk_coalescing: CoalescingTable,

    // === リソース待ちキュー ===
    page_buffer_queue: VecDeque<SuspendedOp>,
    chunk_buffer_queue: VecDeque<SuspendedOp>,
    disk_extent_queue: VecDeque<SuspendedOp>,
    compaction_queue: VecDeque<SuspendedOp>,

    // === Compaction制御 ===
    compaction_state: Option<CompactionStateMachine>,
    compaction_inflight: usize,
    compaction_budget: usize,

    // === その他 ===
    callbacks: C,
    current_version: u32,
    next_job_id: u64,
}
```

**ステートマシン定義:**

```rust
/// 中断された操作
struct SuspendedOp {
    job_id: JobId,
    state: OpStateMachine,
}

/// 全操作のステートマシン（enum、ヒープ確保不要）
enum OpStateMachine {
    Read(ReadState),
    Rmw(RmwState),
    Delete(DeleteState),
    Readdir(ReaddirState),
    Scan(ScanState),
}

/// 各操作の状態（例: Read）
enum ReadState {
    /// hot log indexからchain先頭を取得済み、chain traversal中
    TraverseHotLog {
        key: Key,
        key_hash: u64,
        addr: LogAddress,
        target: ReadTarget,
    },
    /// hot log stable regionのレコードI/O待ち
    WaitHotLogIo {
        key: Key,
        key_hash: u64,
        addr: LogAddress,
        target: ReadTarget,
    },
    /// cold log indexのhash chunk I/O待ち
    WaitColdIndexIo {
        key: Key,
        key_hash: u64,
        target: ReadTarget,
    },
    /// cold logのレコードI/O待ち
    WaitColdLogIo {
        key: Key,
        key_hash: u64,
        addr: LogAddress,
        target: ReadTarget,
    },
    /// chunk dataのI/O待ち（ReadTarget::WithChunk時）
    WaitChunkIo {
        record_addr: LogAddress,
        extent_addr: u64,
        range: Range<u64>,
    },
}

/// RmwState（例）
enum RmwState {
    /// hot log indexからchain先頭を取得済み
    TraverseHotLog {
        key: Key,
        key_hash: u64,
        addr: LogAddress,
        input: RmwInput,
        saved_index_addr: LogAddress,  // I/O中の同一キー操作検出用
    },
    /// hot log stable regionのレコードI/O待ち
    WaitHotLogIo {
        key: Key,
        key_hash: u64,
        addr: LogAddress,
        input: RmwInput,
        saved_index_addr: LogAddress,
    },
    /// cold log検索中
    SearchColdLog {
        key: Key,
        key_hash: u64,
        input: RmwInput,
        saved_index_addr: LogAddress,
    },
    /// extent確保待ち
    WaitExtent {
        key: Key,
        input: RmwInput,
        new_record_addr: LogAddress,
    },
    /// chunk buffer確保待ち
    WaitChunkBuffer {
        key: Key,
        input: RmwInput,
        extent_addr: u64,
        range: Range<u64>,
    },
}
```

**ステートマシンの実行:**

各opsモジュールが `resume` 関数を提供し、Kvs のpoll内で呼ばれる。

```rust
// ops/read.rs
fn resume_read(
    state: ReadState,
    hot_log: &HybridLog<PrimaryRecord>,
    cold_log: &HybridLog<PrimaryRecord>,
    hot_index: &HashIndex,
    cold_index: &ColdLogIndex,
    read_cache: &mut ReadCache,
    chunk_store: &mut ChunkStore,
    ring: &mut IoUring,
    // ...
) -> ResumeResult<ReadResult> {
    match state {
        ReadState::TraverseHotLog { key, key_hash, addr, target } => {
            // chain traversal → Found / NeedIo / NotFoundInHotLog
            ...
        }
        ReadState::WaitHotLogIo { .. } => {
            // I/O完了後の継続処理
            ...
        }
        ...
    }
}

enum ResumeResult<T> {
    /// 操作完了
    Done(Result<T, Error>),
    /// リソース待ちで中断
    Suspended(OpStateMachine),
}
```

**pollの実装:**

```rust
impl<C: RmwCallbacks> Kvs<C> {
    fn poll(&mut self, completions: &mut Vec<Completion>) {
        // Step 1: CQE回収 → coalescing tableからwaiter回収 → resume
        self.process_cqes(completions);

        // Step 2: page buffer待ちキュー
        self.drain_suspended_queue(
            &mut self.page_buffer_queue, completions);

        // Step 3: chunk buffer待ちキュー
        self.drain_suspended_queue(
            &mut self.chunk_buffer_queue, completions);

        // Step 4: disk extent待ちキュー
        self.drain_suspended_queue(
            &mut self.disk_extent_queue, completions);

        // Step 5: compaction進行（バジェット内で）
        self.advance_compaction(completions);

        // Step 6: chunk cache writeback制御
        let actions = self.chunk_store.maintenance(
            self.chunk_buffer_queue.len());
        for (entry_idx, io_req) in actions.writeback_requests {
            self.ring.submit_write(io_req);
        }

        // Step 7: SQE batch submit
        self.ring.submit();
    }

    /// キューからSuspendedOpを取り出してresumeを試行
    fn drain_suspended_queue(
        &mut self,
        queue: &mut VecDeque<SuspendedOp>,
        completions: &mut Vec<Completion>,
    ) {
        let mut retry = VecDeque::new();
        while let Some(op) = queue.pop_front() {
            match self.resume_op(op.state) {
                ResumeResult::Done(result) => {
                    completions.push(Completion {
                        job_id: op.job_id,
                        result,
                    });
                }
                ResumeResult::Suspended(new_state) => {
                    // 再度同じキューまたは別のキューに入る
                    retry.push_back(SuspendedOp {
                        job_id: op.job_id,
                        state: new_state,
                    });
                }
            }
        }
        *queue = retry;
    }
}
```

全ログインスタンスで共通のログ構造体。Record traitに対してgenericで、
状態管理とメモリマッピングのみを担当する。I/O発行やindex管理は外部に委ねる。

**使用箇所:**

| インスタンス | Record型 | flush | 備考 |
|---|---|---|---|
| Primary Hot Log | PrimaryRecord | あり | read cache付属 |
| Primary Cold Log | PrimaryRecord | あり | ほぼ全てdisk |
| Cold-Log Index (hash chunk log) | HashChunkRecord | あり | 小ページ |
| Secondary HybridLog | SecondaryRecord | あり | dirname index |

**Record trait:**

```rust
/// レコードのシリアライズ/デシリアライズを抽象化
trait Record: Sized {
    type Key: Eq + Hash;
    type Value;

    fn key(&self) -> &Self::Key;
    fn key_hash(&self) -> u64;
    fn header(&self) -> &RecordHeader;
    fn header_mut(&mut self) -> &mut RecordHeader;
    fn value(&self) -> &Self::Value;

    /// ページ上のバイト列からレコードを読む
    fn read_from(buf: &[u8], offset: usize) -> Self;
    /// レコードをバイト列に書き込む。書き込んだサイズを返す
    fn write_to(&self, buf: &mut [u8], offset: usize) -> usize;
    /// レコードのシリアライズ後サイズ
    fn serialized_size(&self) -> usize;
}
```

**HybridLog構造体:**

```rust
struct HybridLog<R: Record> {
    config: HybridLogConfig,

    // === アドレス管理 ===
    begin_address: u64,
    head_offset: u64,
    read_only_offset: u64,
    tail_offset: u64,

    // === Circular Buffer ===
    page_frames: Vec<PageFrame>,
    page_size_bits: u32,  // 2^page_size_bits = page size

    _phantom: PhantomData<R>,
}

/// ページフレーム（ref_count付き）
struct PageFrame {
    buffer: AlignedBuffer,
    status: PageStatus,
    /// in-flight I/O参照カウント
    /// I/O SQE発行時にinc_ref、CQE返却時にdec_ref
    /// ref_count > 0のページはevict不可
    ref_count: u32,
}

struct HybridLogConfig {
    /// circular bufferのページ数
    num_pages: usize,
    /// ページサイズ（2のべき乗）
    page_size_bits: u32,
    /// mutable regionの割合（例: 0.9）
    mutable_fraction: f64,
}

enum PageStatus {
    Free,
    Mutable,
    ReadOnly,
    Flushing,  // flush I/O中（ref_count > 0）
    Clean,
    Evicted,
}
```

**evict条件:** `status == Clean かつ ref_count == 0`。
I/O中のページ（flush中やread I/Oのターゲット）はref_count > 0でevictされない。
BlockCacheのDmaChunkと同じref_countパターンで、バッファの安全性を統一的に保証する。

**公開メソッド:**

```rust
impl<R: Record> HybridLog<R> {
    // === 基本操作 ===

    /// tailにレコード領域を確保。ページフレームが足りなければNone
    fn try_allocate(&mut self, size: usize) -> Option<LogAddress>;

    /// ログアドレスからレコードを読む
    /// メモリ上(mutable/read-only)ならSome、ディスク上ならNone
    fn try_read_in_memory(&self, addr: LogAddress) -> Option<&[u8]>;

    /// メモリ上のレコードに可変アクセス（mutable regionのみ）
    fn try_read_mutable(&mut self, addr: LogAddress) -> Option<&mut [u8]>;

    /// アドレスがどのregionにあるか判定
    fn classify_address(&self, addr: LogAddress) -> AddressRegion;

    // === ページ管理 ===

    /// read-only / head offsetを進める（tail成長に伴い呼ばれる）
    fn advance_offsets(&mut self) -> FlushActions;

    /// ページflush SQEの情報を取得 + ref_countインクリメント
    fn prepare_flush(&mut self, page_idx: usize) -> IoRequest;

    /// flush完了通知（CQE処理後に呼ぶ）→ ref_countデクリメント + Clean遷移
    fn complete_flush(&mut self, page_idx: usize);

    /// ページread I/O準備 + ref_countインクリメント
    fn prepare_page_read(&mut self, addr: LogAddress) -> IoRequest;

    /// ページread完了通知 → ref_countデクリメント
    fn complete_page_read(&mut self, addr: LogAddress);

    /// BEGINをUNTILまで進める（compaction後のtruncation）
    /// ref_count > 0のページはtruncateしない
    fn truncate(&mut self, until: LogAddress);

    // === Snapshot支援 ===

    /// read-only offsetを強制的にtailまで進める（mark_snapshot用）
    fn force_read_only_to_tail(&mut self);

    // === 情報取得 ===
    fn tail_offset(&self) -> LogAddress;
    fn begin_address(&self) -> LogAddress;
    fn head_offset(&self) -> LogAddress;
    fn read_only_offset(&self) -> LogAddress;
}

enum AddressRegion {
    Invalid,     // < begin_address
    Stable,      // < head_offset (ディスク上)
    ReadOnly,    // < read_only_offset
    Mutable,     // >= read_only_offset
}

/// advance_offsetsが返すアクション
struct FlushActions {
    /// flushすべきページのリスト
    pages_to_flush: Vec<usize>,
    /// evict可能になったページのリスト
    pages_to_evict: Vec<usize>,
}
```

HybridLogはI/O発行を行わない。FlushActionsやIoRequestを返し、
呼び出し元（scheduler / IO層）が実際のio_uring操作を実行する。

### 8.4 HashIndex

key_hash → chain先頭アドレスのマッピングを管理する純粋なハッシュテーブル。
Hot-Log IndexとSecondary Indexで共用する。
hash chainのtraversalはKvs層がHybridLogのレコード読み出しを通じて行う。

```rust
/// バケットエントリ（8バイト）
#[repr(C)]
struct BucketEntry {
    /// tag: 15 bit, address: 48 bit, reserved: 1 bit
    raw: u64,
}

impl BucketEntry {
    fn tag(&self) -> u16;
    fn address(&self) -> LogAddress;
    fn is_empty(&self) -> bool;
    fn set(&mut self, tag: u16, address: LogAddress);
    fn clear(&mut self);
}

/// バケット（64バイト = キャッシュライン）
#[repr(C, align(64))]
struct Bucket {
    entries: [BucketEntry; 7],
    overflow: u64,
}

/// Hash Index本体
struct HashIndex {
    buckets: Vec<Bucket>,
    bucket_bits: u32,
    overflow_alloc: OverflowAllocator,
}

impl HashIndex {
    /// tagが一致するエントリのアドレスを返す
    fn find_entry(&self, key_hash: u64) -> Option<LogAddress>;

    /// エントリを挿入
    fn insert_entry(&mut self, key_hash: u64, address: LogAddress)
        -> Result<(), IndexFull>;

    /// エントリのアドレスを更新（RCU, compaction後）
    fn update_entry(&mut self, key_hash: u64,
                    old_address: LogAddress, new_address: LogAddress) -> bool;

    /// エントリを削除
    fn remove_entry(&mut self, key_hash: u64, address: LogAddress) -> bool;

    /// 指定アドレス以下のエントリを全て無効化（truncation用）
    fn invalidate_below(&mut self, min_valid_address: LogAddress);

    /// 全エントリのイテレータ（snapshot scan用）
    fn iter_entries(&self) -> HashIndexIter;
}
```

**Chain traversalのパターン（Kvs層）:**

```rust
// Kvs層でのchain traversal
fn find_record(&self, key: &Key) -> FindResult {
    let key_hash = hash(key);
    let head_addr = match self.hot_index.find_entry(key_hash) {
        Some(addr) => addr,
        None => return FindResult::NotFound,
    };

    let mut addr = head_addr;
    loop {
        match self.hot_log.classify_address(addr) {
            Mutable | ReadOnly => {
                let buf = self.hot_log.try_read_in_memory(addr).unwrap();
                let record = PrimaryRecord::read_from(buf, 0);
                if record.key() == key {
                    return FindResult::Found(addr, record);
                }
                addr = record.header().previous_address();
                if addr == 0 { break; }
            }
            Stable => {
                return FindResult::NeedIo(addr);
            }
            Invalid => break,
        }
    }
    FindResult::NotFoundInHotLog
}
```

### 8.5 ColdLogIndex

Cold Log専用の2-level index。メモリ上のHashIndex（1st level）と
ディスク上のhash chunk log（2nd level、HybridLogインスタンス）で構成される。

```rust
struct ColdLogIndex {
    /// 1st level: hash chunk addressへのマッピング
    chunk_index: HashIndex,
    /// 2nd level: hash chunk log
    chunk_log: HybridLog<HashChunkRecord>,
}

/// Hash Chunk（256バイト、32エントリ）
#[repr(C)]
struct HashChunk {
    entries: [ColdLogEntry; 32],
}

#[repr(C)]
struct ColdLogEntry {
    /// key hashの一部（tag）
    tag: u16,
    /// cold log上のレコードアドレス（0 = 空）
    address: u48,
}

impl ColdLogIndex {
    /// キーのhash値からcold logのレコードアドレスを取得
    fn find_entry(&self, key_hash: u64) -> ColdLookupResult;

    /// エントリを追加（hot-cold compaction時）
    fn insert_entry(&mut self, key_hash: u64, address: LogAddress) -> IoAction;

    /// エントリを削除（cold-cold compaction truncation後）
    fn remove_entry(&mut self, key_hash: u64, address: LogAddress) -> IoAction;
}

enum ColdLookupResult {
    /// hash chunkがメモリ上にあり、エントリが見つかった
    Found(LogAddress),
    /// hash chunkがメモリ上にあり、エントリが見つからなかった
    NotFound,
    /// hash chunkの読み出しにI/Oが必要
    NeedIo(IoRequest),
}

/// I/O発行が必要か、メモリ上で完了したかを示す
enum IoAction {
    Done,
    NeedIo(IoRequest),
}
```

### 8.6 ReadCache

Hot Logに付属するflushなしのHybridLogインスタンス。
Hot-Log Indexのhash chainを拡張し、read cacheレコードも含む。

```rust
struct ReadCache {
    /// flushなしのHybridLog（mutable + read-only regionのみ）
    log: HybridLog<PrimaryRecord>,
}

impl ReadCache {
    /// ディスクから読んだレコードをread cacheに挿入
    /// hash chainの先頭に挿入し、hot-log indexのエントリを更新
    fn insert(
        &mut self,
        record: &PrimaryRecord,
        hot_index: &mut HashIndex,
    ) -> Option<LogAddress>;

    /// 指定キーのread cacheエントリを無効化（RMW/Delete時）
    fn invalidate(&mut self, key_hash: u64, hot_index: &mut HashIndex);

    /// eviction（ページ単位でread cacheから追い出し）
    /// hash chainの再接続処理を含む
    fn evict_page(&mut self, hot_index: &mut HashIndex);
}
```

Read CacheがHashIndexのmutable参照を受け取るのは、
hash chainの付け替え（read cache record → hot log recordへの再接続）が必要なため。
Kvs層から呼ばれる際にhot_indexが一緒に渡される。

### 8.7 モジュール間の責務分離

```
HashIndex:     key_hash → chain先頭アドレス（純粋なハッシュテーブル）
HybridLog<R>:  ログ構造 + ページ管理 + アドレス空間（レコード格納）
ColdLogIndex:  2-level index（HashIndex + HybridLog<HashChunkRecord>）
ReadCache:     flushなしHybridLog + HashIndex操作（read-hot record管理）
```

**HybridLog が持たないもの:**
- Hash Index（外部で管理）
- Read Cache（Hot Log専用、外部で管理）
- I/O発行（FlushActions / IoRequest を返すのみ）
- Compactionロジック（外部のcompactionモジュールがtruncateを呼ぶ）
- Snapshot管理（SnapshotManagerがforce_read_only_to_tailを呼ぶ）

**Kvs\<C\> が統合するもの:**
- Primary: HybridLog\<PrimaryRecord\> (hot) + HybridLog\<PrimaryRecord\> (cold)
  + HashIndex (hot-log index) + ColdLogIndex + ReadCache
- Secondary: HybridLog\<SecondaryRecord\> + HashIndex
- ChunkStore: ExtentAllocator + BlockCache + DmaChunk
- IO: IoUringWrapper + CoalescingTable (page/chunk)
- Snapshot: SnapshotManager

### 8.8 IO層

#### IoUringWrapper

io_uringのSQE発行/CQE回収を管理するシンプルなラッパー。
IoTokenプールでuser_dataとI/O操作の対応を管理する。

```rust
/// SQEに紐づけるユーザーデータ
struct IoToken {
    kind: IoKind,
    /// CoalescingTableのキー（block/page address）
    coalescing_key: u64,
}

enum IoKind {
    PageRead,        // HybridLog page read
    PageFlush,       // HybridLog page flush (write)
    ChunkRead,       // Chunk block read
    ChunkWriteback,  // Chunk block writeback (write)
}

struct IoUringWrapper {
    ring: io_uring::IoUring,
    /// IoTokenプール（user_data = このVecのindex）
    tokens: Vec<Option<IoToken>>,
    /// free token indices
    free_tokens: Vec<usize>,
    /// 未submitのSQE数
    pending_sqe_count: usize,
}

impl IoUringWrapper {
    /// read SQEを準備（submitはまだ）
    fn prepare_read(
        &mut self,
        fd: RawFd,
        buf: *mut u8,
        len: u32,
        offset: u64,
        token: IoToken,
    ) -> Result<(), QueueFull>;

    /// write SQEを準備
    fn prepare_write(
        &mut self,
        fd: RawFd,
        buf: *const u8,
        len: u32,
        offset: u64,
        token: IoToken,
    ) -> Result<(), QueueFull>;

    /// 蓄積したSQEを一括submit
    fn submit(&mut self) -> io::Result<usize>;

    /// CQEを回収。callbackにIoTokenと結果を渡す
    fn collect_cqes<F>(&mut self, callback: F)
    where
        F: FnMut(IoToken, io::Result<u32>);

    /// in-flight I/O数
    fn inflight_count(&self) -> usize;
}
```

I/O対象バッファのポインタはprepare_read/prepare_writeに渡されるが、
IoUringWrapperはバッファを所有しない。
バッファの安全性（I/O中のevict防止）はHybridLogのPageFrame.ref_count
およびBlockCacheのCacheEntry.ref_countで保証される。

#### CoalescingTable

同一アドレスへの重複I/Oを検出し、待ち合わせを管理する。
page用とchunk用で共用される汎用構造体。
バッファは所有せず、waiterの管理のみに徹する。

```rust
struct CoalescingTable {
    table: HashMap<u64, CoalescingEntry>,
}

struct CoalescingEntry {
    /// I/O完了待ちの全操作
    waiters: Vec<SuspendedOp>,
}

impl CoalescingTable {
    /// I/O要求を登録
    /// 既にin-flight I/Oがあればwaiterに追加（相乗り）
    /// なければ新規エントリ作成（I/O発行が必要）
    fn request(&mut self, addr: u64, op: SuspendedOp) -> CoalescingAction;

    /// CQE返却時に呼ぶ。該当エントリの全waiterを返す
    fn complete(&mut self, addr: u64) -> Vec<SuspendedOp>;

    /// 特定アドレスのin-flight I/Oが存在するか
    fn has_inflight(&self, addr: u64) -> bool;
}

enum CoalescingAction {
    /// 新規エントリ作成。呼び出し元がI/O SQEを発行すべき
    NewEntry,
    /// 既存エントリに相乗り。I/O発行不要
    Coalesced,
}
```

**I/O発行からCQE処理までの流れ（Kvs.poll内）:**

```
操作がディスク読み出しを必要とする:
  1. coalescing_table.request(addr, suspended_op) を呼ぶ
  2. NewEntry → バッファ所有元でref_count inc
              → IoUringWrapper.prepare_read(fd, buf, len, offset, token)
     Coalesced → 何もしない（I/O完了を待つ）

CQE返却:
  1. IoUringWrapper.collect_cqes() でIoTokenを取得
  2. IoToken.kindに応じてバッファ所有元でref_count dec
  3. coalescing_table.complete(token.coalescing_key) で全waiterを取得
  4. 各waiterのステートマシンをresumeする
```

**バッファ安全性の統一パターン:**

HybridLog PageFrameとBlockCache CacheEntryの両方で
同じref_countパターンを使用する。

```
I/O SQE発行前:  ref_count++  → evict不可
I/O CQE返却後:  ref_count--  → ref_count == 0 かつ Clean/Stale ならevict可能
```

これにより、I/O中のバッファが再利用されることは決してない。
ポインタベースのバッファ渡し（ヒープ確保不要）でありながら安全性を保証する。

### 8.9 BlockCache

extentのディスクブロック（4KiB）をキャッシュする。
DmaChunkのバッキングメモリとしても機能する。
CLOCK方式のevictionと適応的writeback制御を実装する。

**キャッシュエントリ:**

```rust
/// ブロックの状態
enum BlockStatus {
    Free,      // 未使用、確保可能
    Clean,     // ディスクと同一内容、evict可能（ref_count == 0の場合）
    Dirty,     // メモリのみ変更あり、evict不可
    Pinned,    // writeback I/O中、evict不可
    Stale,     // extent CoW/上書きで不要、Free化可能（ref_count == 0の場合）
}

struct CacheEntry {
    /// このエントリが保持するディスクブロックのアドレス
    /// INVALID_ADDR = 未割り当て
    disk_block_addr: u64,
    status: BlockStatus,
    /// CLOCK参照ビット
    reference_bit: bool,
    /// DmaChunk経由の参照数（DmaChunkのClone/Dropで直接増減）
    ref_count: u32,
    /// 4KiB aligned buffer
    buffer: AlignedBuffer4K,
}
```

**evictとwritebackの条件:**

```
evict可能:     (Clean or Stale) かつ ref_count == 0
writeback可能: Dirty かつ ref_count == 0
```

ref_count > 0のDirtyエントリはwritebackしない。
io_uringのwrite SQE発行後もDMA完了までバッファを参照し続けるため、
DmaChunkがliveの間（ref_count > 0）にwritebackすると
DMAとユーザーの書き込みが競合する。
DmaChunkがdropされてref_count == 0になってからwritebackする。

**BlockCache構造体:**

```rust
struct BlockCache {
    entries: Vec<CacheEntry>,
    /// disk_block_addr → entry index のルックアップ
    addr_map: HashMap<u64, usize>,
    /// CLOCK handの位置
    clock_hand: usize,
    /// 統計
    free_count: usize,
    clean_count: usize,
    dirty_count: usize,
    pinned_count: usize,
    stale_count: usize,
}
```

drop_queueは不要。DmaChunkがBlockCacheへの生ポインタを保持し、
Clone/Drop時にinc_ref/dec_refを直接呼ぶ。
プロセス生存期間中はBlockCacheのアドレスが不変であるため、
生ポインタの安全性は保証される。

**公開メソッド:**

```rust
impl BlockCache {
    // === ルックアップ ===

    /// ディスクブロックアドレスでキャッシュを検索
    fn lookup(&self, disk_block_addr: u64) -> Option<usize>;

    // === エントリ確保 ===

    /// 新しいエントリをCLOCK方式で確保
    /// Free → Stale(ref==0) → Clean(ref==0) の優先順でevict
    /// 確保できなければNone
    fn try_alloc_entry(&mut self) -> Option<usize>;

    /// エントリにディスクブロックを紐づけ（I/O read完了後）
    fn assign(&mut self, entry_idx: usize, disk_block_addr: u64);

    // === 参照カウント（DmaChunkから直接呼ばれる）===

    /// ref_countインクリメント
    fn inc_ref(&mut self, entry_idx: usize);

    /// ref_countデクリメント
    /// ref_count == 0になったらDirtyに遷移
    fn dec_ref(&mut self, entry_idx: usize);

    // === 状態遷移 ===

    /// Staleにする（extent CoW時、旧extentの全ブロック）
    fn mark_stale(&mut self, disk_block_addr: u64);

    /// writeback SQE発行前にDirty → Pinned
    fn mark_pinned(&mut self, entry_idx: usize);

    /// writeback CQE返却後にPinned → Clean
    fn complete_writeback(&mut self, entry_idx: usize);

    // === バッファアクセス ===

    fn buffer(&self, entry_idx: usize) -> &AlignedBuffer4K;
    fn buffer_mut(&mut self, entry_idx: usize) -> &mut AlignedBuffer4K;

    // === Writeback制御 ===

    /// writeback候補を選択（Dirty かつ ref_count == 0）
    fn select_writeback_candidates(&self, budget: usize) -> Vec<usize>;

    /// 確保可能なエントリ数（eviction込み）
    fn available_count(&self) -> usize;
}
```

### 8.10 DmaChunk

BlockCache上のエントリへの参照。ヒープ確保不要の値型。
BlockCacheへの生ポインタを保持し、Clone/Dropで直接ref_countを増減する。

```rust
/// ゼロコピーチャンクバッファ参照（値型、32バイト）
struct DmaChunk {
    /// BlockCacheへの生ポインタ（プロセス生存期間中有効）
    cache: *mut BlockCache,
    /// 対応するCacheEntryのindex
    cache_entry_idx: usize,
    /// バッファへの生ポインタ
    buffer_ptr: *mut u8,
    /// この参照がカバーする範囲（ブロック内offset）
    offset: u32,
    length: u32,
}

impl DmaChunk {
    fn as_mut_slice(&self) -> &mut [u8] {
        unsafe {
            std::slice::from_raw_parts_mut(
                self.buffer_ptr.add(self.offset as usize),
                self.length as usize,
            )
        }
    }

    fn as_slice(&self) -> &[u8] {
        unsafe {
            std::slice::from_raw_parts(
                self.buffer_ptr.add(self.offset as usize),
                self.length as usize,
            )
        }
    }
}

impl Clone for DmaChunk {
    fn clone(&self) -> Self {
        unsafe { (*self.cache).inc_ref(self.cache_entry_idx) };
        Self { ..*self }
    }
}

impl Drop for DmaChunk {
    fn drop(&mut self) {
        unsafe { (*self.cache).dec_ref(self.cache_entry_idx) };
    }
}

// Send/Syncは実装しない（シングルスレッド前提）
```

**DmaChunkのライフサイクル:**

```
1. rmw(key, chunk_range) → BlockCacheでエントリ確保 + inc_ref
   → DmaChunk生成（値型、スタック上）→ ユーザーに返却

2. ユーザーがDmaChunk経由でバッファに書き込み
   （RDMA WRITE or memcpy）
   ユーザーはDmaChunkをclone可能（inc_ref）

3. 全DmaChunkのコピーがdrop
   → dec_ref → ref_count == 0 → status = Dirty（即座に遷移）

4. writeback制御 → Dirty(ref==0)を選択 → SQE発行 → Pinned
   → CQE返却 → Clean → evict可能
```

drop_queueを経由せず即座にref_countが更新されるため、
pollを待たずに状態遷移が完了する。

**複数ブロックにまたがるextent:**

1つのextentが複数の4KiBブロックで構成される場合、
rmwは要求範囲をカバーする全ブロックについてCacheEntryを確保し、
各ブロックに対応するDmaChunkを生成する。
ユーザーには連続領域に見えるように範囲を調整して返す。

ただし、extentが複数ブロックにまたがる場合、
物理的に不連続なキャッシュバッファを連続に見せるのは困難。
選択肢として:

**案A: ブロック単位でDmaChunkを返す。** ユーザーが複数のDmaChunkを受け取る。
scatter-gather的な使い方。RDMAのSGEリストと親和性が高い。

**案B: 連続バッファにコピー。** 取得時に連続バッファにコピーし、
drop時にキャッシュブロックに書き戻す。ゼロコピーの利点が失われる。

**案C: extentのブロック配置をキャッシュ上で連続にする。**
extent割り当て時にキャッシュエントリも連続確保する。
キャッシュの断片化制御が複雑になる。

案Aが最もシンプルで、RDMA環境との親和性も高い。

```rust
struct RmwResult {
    /// 要求範囲をカバーするDmaChunkのリスト（ブロック単位）
    chunks: Vec<DmaChunk>,
}
```

### 8.11 ExtentAllocator（再掲・詳細）

Section 7.3で定義済みのBitmap方式Extent Allocatorの詳細インターフェース。

```rust
struct ExtentAllocator {
    /// 4KiBブロック単位のbitmap
    bitmap: Vec<u64>,
    /// next-fit位置
    next_scan_pos: usize,
    total_blocks: usize,
    free_blocks: usize,
}

impl ExtentAllocator {
    /// 連続block_count個のフリーブロックを確保
    fn try_alloc(&mut self, block_count: u32) -> Option<ExtentHandle>;

    /// extentを解放
    fn free(&mut self, addr: u64, block_count: u32);

    /// HybridLog走査結果から状態を復元
    fn recover_from_log(&mut self, live_extents: &[(u64, u32)]);

    /// フリーブロック数
    fn free_blocks(&self) -> usize;
}

/// 確保されたextentのハンドル
struct ExtentHandle {
    /// ディスク上の開始ブロックアドレス
    addr: u64,
    /// ブロック数
    block_count: u32,
}
```

### 8.12 ChunkStore統合

BlockCache、DmaChunk、ExtentAllocatorを統合するChunkStore。
Kvs層から使われるfacade。

```rust
struct ChunkStore {
    cache: BlockCache,
    extent_alloc: ExtentAllocator,
}

impl ChunkStore {
    /// extentの指定範囲のDmaChunkを取得
    /// キャッシュミス時はNeedIoを返す
    fn acquire_chunks(
        &mut self,
        extent_addr: u64,
        range: Range<u64>,
    ) -> ChunkAcquireResult;

    /// 新しいextentを確保
    fn alloc_extent(&mut self, block_count: u32) -> Option<ExtentHandle>;

    /// extentを解放
    fn free_extent(&mut self, addr: u64, block_count: u32);

    /// extent CoW時に旧extentのキャッシュエントリをStale化
    fn mark_extent_stale(&mut self, addr: u64, block_count: u32);

    /// writeback制御（poll内で呼ばれる）
    fn maintenance(&mut self, chunk_buffer_queue_len: usize) -> MaintenanceActions;
}

enum ChunkAcquireResult {
    /// 全ブロックがキャッシュ上にあり、DmaChunkを返却可能
    Ready(Vec<DmaChunk>),
    /// 一部ブロックのディスク読み出しが必要
    NeedIo(Vec<IoRequest>),
    /// キャッシュエントリが確保できない
    NeedBuffer,
}

struct MaintenanceActions {
    /// writeback SQEを発行すべきエントリのリスト
    writeback_requests: Vec<(usize, IoRequest)>,
}
```

---

## 9. 全体アーキテクチャ図

```
┌───────────────────────────────────────────────────────────────────┐
│                      イベントループ (io_uring)                       │
│                                                                   │
│  ┌───────────────────────────────────────────────────────────┐    │
│  │              ステートマシン駆動                              │    │
│  │                                                           │    │
│  │  操作の任意の時点でリソース待ち → 対応キューに中断            │    │
│  │  リソース利用可能 → 中断した地点から再開                      │    │
│  │                                                           │    │
│  │  ┌─────────────────────────────────────────────────────┐  │    │
│  │  │  6つのキュー                                         │  │    │
│  │  │  ┌─────────────────┐  ┌──────────────────┐         │  │    │
│  │  │  │ Page Coalescing  │  │ Chunk Coalescing  │         │  │    │
│  │  │  └─────────────────┘  └──────────────────┘         │  │    │
│  │  │  ┌─────────────────┐  ┌──────────────────┐         │  │    │
│  │  │  │ Page Buffer Q    │  │ Chunk Buffer Q    │         │  │    │
│  │  │  └─────────────────┘  └──────────────────┘         │  │    │
│  │  │  ┌─────────────────┐  ┌──────────────────┐         │  │    │
│  │  │  │ Disk Extent Q    │  │ Compaction Q      │         │  │    │
│  │  │  └─────────────────┘  └──────────────────┘         │  │    │
│  │  └─────────────────────────────────────────────────────┘  │    │
│  │                          │                                │    │
│  │                   ┌──────▼─────────┐                      │    │
│  │                   │  io_uring      │                      │    │
│  │                   │  SQE/CQE       │                      │    │
│  │                   └────────────────┘                      │    │
│  └───────────────────────────────────────────────────────────┘    │
│                                                                   │
│  ┌───────────────────────────────────────────────────────────┐    │
│  │              バッファプール                                  │    │
│  │  ┌────────────────────┐  ┌──────────────────────┐        │    │
│  │  │ Page Buffer Pool   │  │ Chunk Buffer Pool    │        │    │
│  │  │ (HybridLog pages)  │  │ (4KiB aligned, Rc)   │        │    │
│  │  └────────────────────┘  └──────────────────────┘        │    │
│  └───────────────────────────────────────────────────────────┘    │
│                                                                   │
│  ┌───────────────────────────────────────────────────────────┐    │
│  │                  Primary Storage                           │    │
│  │  ┌───────────────────────────────────────────────────┐    │    │
│  │  │         Hash Index (hot-log / cold-log)            │    │    │
│  │  └──────────────────────┬────────────────────────────┘    │    │
│  │  ┌──────────┬───────────┴────────────┬──────────────┐    │    │
│  │  │Read Cache│      Hot Log           │   Cold Log    │    │    │
│  │  │ (memory) │ Mutable|RO|Stable      │  (mostly disk)│    │    │
│  │  └──────────┴────────────────────────┴──────────────┘    │    │
│  └───────────────────────────────────────────────────────────┘    │
│                                                                   │
│  ┌───────────────────────────────────────────────────────────┐    │
│  │               Secondary Storage (dirname index)            │    │
│  │  ┌───────────────────────────────────────────────────┐    │    │
│  │  │         Hash Index (dirname)                       │    │    │
│  │  └──────────────────────┬────────────────────────────┘    │    │
│  │  ┌──────────────────────┴────────────────────────────┐    │    │
│  │  │      Secondary HybridLog (Mutable|RO|Stable)      │    │    │
│  │  │      record = [dirname | hash_1, hash_2, ...]     │    │    │
│  │  └───────────────────────────────────────────────────┘    │    │
│  └───────────────────────────────────────────────────────────┘    │
│                                                                   │
│  ┌───────────────────────────────────────────────────────────┐    │
│  │           ChunkStore (Extent Allocator)                    │    │
│  │     ┌──────────────┐  ┌───────────────────┐              │    │
│  │     │ LRU Block    │  │ Extent Blocks     │              │    │
│  │     │ Cache (mem)  │  │ (disk, 4KiB align) │              │    │
│  │     └──────────────┘  └───────────────────┘              │    │
│  └───────────────────────────────────────────────────────────┘    │
│                                                                   │
│  ┌───────────────────────────────────────────────────────────┐    │
│  │           Snapshot管理                                     │    │
│  │  active_snapshots: Vec<SnapshotState>                     │    │
│  │  各snapshot: snap_diff + snap_min_address + snapshot_tail │    │
│  │  ※ Primary / Secondary 両方のHybridLogに適用               │    │
│  │  ※ 複数snapshotの同時存在をサポート                         │    │
│  │  ※ Pull型scan API (scan_snapshot_start / scan_next)       │    │
│  └───────────────────────────────────────────────────────────┘    │
└───────────────────────────────────────────────────────────────────┘
```

---

## 10. 補足: 実装詳細

### 10.1 Hash Chainの構造

hash chainは、hash index entry → 最新レコード → (previous_address) → 古いレコード → ... → 0 の
逆順リンクリストである。

- 同じ(offset, tag)を持つが**異なるキー**のレコードも同じchainに入る（tag衝突）
- 同じキーの**異なるバージョン**（RCUで作られた新旧レコード）も同じchainに入る
- chain traversalでは各レコードのキーを実際に比較して一致を確認する必要がある
- index entryは常にchain内の最新レコード（最も高いlog address）を指す

```
HashIndex bucket entry (tag=T, addr=300)
  → Record@300 (key=A, prev=200)    ← 最新のkey A
    → Record@200 (key=B, prev=100)  ← 最新のkey B（tag衝突）
      → Record@100 (key=A, prev=0)  ← 古いkey A（RCU前のバージョン）
        → chain終端 (prev=0)
```

### 10.2 RCU（Read-Copy-Update）手順

Read-Only/Stable regionのレコードを更新する場合のRCU手順:

```
RCU(key, old_record_addr, new_attr):
  1. new_size = 新レコードのシリアライズサイズを計算
  2. new_addr = hot_log.try_allocate(new_size)
     → None なら page_buffer_queue で中断
  3. 新レコードを構築:
     header.previous_address = old_record.header.previous_address
       （旧レコードの prev を引き継ぐ。旧レコード自身を指すのではない）
     header.invalid = 0
     header.tombstone = 0
     version = current_version
     key = old_record.key
     value = new_attr
     extent_addr/length = (snapshot CoWの場合は新extent、そうでなければ旧値コピー)
  4. 新レコードをhot_log tail上のページバッファに書き込み (encode)
  5. hot_index.update_entry(key_hash, old_index_addr, new_addr)
     ※ old_index_addr = index entryが指していたアドレス（chain先頭）
     ※ new_addr の prev は old_record の prev を指す
     → 旧レコード（old_record_addr）はchainから外れ、compactionで回収対象になる
```

重要: step 3で previous_address に旧レコードのprevious_addressをコピーする。
これにより旧レコードがchainから外れ、新レコードが旧レコードの位置を引き継ぐ。

### 10.3 LogAddress

LogAddressはu64の論理アドレスで、ページ番号とページ内オフセットに分解される。

```rust
type LogAddress = u64;

const INVALID_ADDRESS: LogAddress = 0;

impl LogAddress {
    /// ページ番号（上位ビット）
    fn page_number(self, page_size_bits: u32) -> u64 {
        self >> page_size_bits
    }
    /// ページ内オフセット（下位ビット）
    fn page_offset(self, page_size_bits: u32) -> usize {
        (self & ((1u64 << page_size_bits) - 1)) as usize
    }
    /// circular buffer内のフレームインデックス
    fn frame_index(self, page_size_bits: u32, num_pages: usize) -> usize {
        (self.page_number(page_size_bits) as usize) % num_pages
    }
}
```

### 10.4 Secondary HybridLogレコードフォーマット

```
Secondary Record Layout:
  ┌──────────────────────────────────────────┐
  │ Record Header (8 bytes)                   │
  │   previous_address: 48 bit               │
  │   invalid: 1 bit, tombstone: 1 bit       │
  │   reserved: 14 bit                       │
  ├──────────────────────────────────────────┤
  │ Version (4 bytes)                         │
  │   version: u32                            │
  ├──────────────────────────────────────────┤
  │ Key (variable length)                     │
  │   dirname_len: u16                        │
  │   dirname: [u8; dirname_len]              │
  ├──────────────────────────────────────────┤
  │ Value                                     │
  │   hash_count: u32 (配列容量、doublingで成長) │
  │   live_count: u32 (非tombstoneエントリ数)   │
  │   hashes: [u64; hash_count]              │
  │   ※ 0x0000000000000000 = tombstone        │
  └──────────────────────────────────────────┘
```

extent_addr/extent_lengthフィールドはSecondaryレコードには存在しない。

### 10.5 HashChunkRecordフォーマット（Cold-Log Index用）

Cold-Log Indexのhash chunk logに格納されるレコード。
F2の設計に基づき、256バイトのhash chunkに32エントリを格納する。

```
HashChunkRecord Layout:
  ┌──────────────────────────────────────────┐
  │ Record Header (8 bytes)                   │
  │   previous_address: 48 bit               │
  │   invalid: 1 bit                         │
  │   reserved: 15 bit                       │
  ├──────────────────────────────────────────┤
  │ Key (8 bytes)                             │
  │   chunk_id: u64                          │
  │   (key hashの上位ビットで決まる            │
  │    hash chunkの識別子)                    │
  ├──────────────────────────────────────────┤
  │ Value: Hash Chunk (256 bytes)             │
  │   entries: [ColdLogEntry; 32]            │
  │                                          │
  │   ColdLogEntry (8 bytes each):           │
  │     tag:     u16 (key hashの一部)         │
  │     address: u48 (cold log上のレコード     │
  │              アドレス。0 = 空エントリ)      │
  │                                          │
  │   8 bytes × 32 = 256 bytes               │
  └──────────────────────────────────────────┘
  合計: 8 + 8 + 256 = 272 bytes (固定長)
```

- **chunk_id:** key hashの上位ビットから計算される。同じchunk_idを持つキーは同じhash chunkに格納される。
- **ColdLogEntry.tag:** key hashの別のビット部分。chunk内でのキー識別に使用。
- **ColdLogEntry.address:** cold log上のレコードのLogAddress。0は空エントリ。
- tombstoneフィールドはHashChunkRecordには不要（cold logレコード側で管理）。

Hash chunkの検索・更新:
```
find: chunk_id → hash chunk logでRecord検索 → chunk内でtag一致エントリを探す
insert: chunk_id → hash chunk logでRMW → 空エントリにtag + addressを書き込み
remove: chunk_id → hash chunk logでRMW → 該当エントリのaddressを0にクリア
```

### 10.6 IoRequest

```rust
struct IoRequest {
    /// 読み書き対象のファイルディスクリプタ
    fd: RawFd,
    /// バッファポインタ（read先 or write元）
    buf: *mut u8,
    /// I/Oサイズ（バイト）
    len: u32,
    /// ファイル内オフセット
    file_offset: u64,
    /// 読み出しか書き込みか
    direction: IoDirection,
}

enum IoDirection {
    Read,
    Write,
}
```

### 10.7 AlignedBuffer

Direct I/O用のアライン済みバッファ。posix_memalignベースで確保する。

```rust
struct AlignedBuffer {
    ptr: *mut u8,
    len: usize,
    align: usize,  // 通常4096
}

impl AlignedBuffer {
    fn new(len: usize, align: usize) -> Self {
        let ptr = unsafe {
            let mut p = std::ptr::null_mut();
            libc::posix_memalign(&mut p, align, len);
            p as *mut u8
        };
        Self { ptr, len, align }
    }
}

impl Drop for AlignedBuffer {
    fn drop(&mut self) {
        unsafe { libc::free(self.ptr as *mut libc::c_void) };
    }
}
```

**PageFrame用:** posix_memalignで確保したバッファをSlab allocatorで管理。
ページサイズ × ページ数の大きなバッファを一括確保し、
ページフレームごとにスライスして使用する。

**CacheEntry用（4KiB）:** ExtentAllocator用のメモリプール。
4KiB × エントリ数の大きなバッファを一括確保し、
エントリごとにスライスして使用する。

### 10.8 OverflowAllocator

HashIndexのoverflow bucket用Slab allocator。

```rust
struct OverflowAllocator {
    /// 64バイトアラインのBucket配列
    slabs: Vec<AlignedBuffer>,
    /// フリーリスト（空きBucketへのポインタ/インデックス）
    free_list: Vec<u64>,
}

impl OverflowAllocator {
    fn alloc(&mut self) -> u64;   // overflow bucket pointer
    fn free(&mut self, ptr: u64);
}
```

### 10.9 Compactionステートマシン

```rust
enum CompactionStateMachine {
    HotCold(HotColdCompactionState),
    ColdCold(ColdColdCompactionState),
    Idle,
}

enum HotColdCompactionState {
    /// compaction範囲 [BEGIN, UNTIL] の決定
    DetermineRange,
    /// source logからレコード読み出し
    ReadRecord { current_addr: LogAddress, until: LogAddress },
    /// レコードのI/O待ち
    WaitReadIo { current_addr: LogAddress, until: LogAddress },
    /// liveness判定（index lookup）
    CheckLiveness { current_addr: LogAddress, until: LogAddress, record: Vec<u8> },
    /// liveレコードをcold log tailにコピー
    CopyToColdLog { current_addr: LogAddress, until: LogAddress, record: Vec<u8> },
    /// cold-log indexにエントリ追加（hash chunk RMW）
    UpdateColdIndex { current_addr: LogAddress, until: LogAddress },
    /// 全レコード処理完了、truncation
    Truncate { until: LogAddress },
}

enum ColdColdCompactionState {
    DetermineRange,
    ReadRecord { current_addr: LogAddress, until: LogAddress },
    WaitReadIo { current_addr: LogAddress, until: LogAddress },
    CheckLiveness { current_addr: LogAddress, until: LogAddress, record: Vec<u8> },
    CopyToTail { current_addr: LogAddress, until: LogAddress, record: Vec<u8> },
    Truncate { until: LogAddress },
}
```

### 10.10 初期化パラメータ

```rust
struct KvsConfig {
    // === Hot Log ===
    /// hot-log indexのバケット数（2のべき乗）
    /// 目安: 100Mキーなら 64M buckets (512MiB)
    hot_index_buckets: usize,
    /// hot log in-memory region サイズ
    /// mutable 90% + read-only 10%
    hot_log_memory: usize,
    /// hot logページサイズ（2のべき乗、例: 2^22 = 4MiB）
    hot_log_page_size_bits: u32,
    /// hot logディスクbudget（これを超えるとhot-cold compaction）
    hot_log_disk_budget: u64,

    // === Cold Log ===
    cold_log_memory: usize,       // 小さい（例: 64MiB）
    cold_log_page_size_bits: u32,
    cold_log_disk_budget: u64,

    // === Cold-Log Index ===
    /// hash chunkサイズ（例: 256B = 32エントリ）
    cold_index_chunk_size: usize,
    /// cold-log index用hash table buckets
    cold_index_buckets: usize,
    cold_index_memory: usize,     // 小さい（例: 64MiB）

    // === Read Cache ===
    /// read cache サイズ（例: 1GiB）
    read_cache_memory: usize,

    // === Chunk Cache ===
    /// chunk block cache エントリ数（例: 2GiB / 4KiB = 524288）
    chunk_cache_entries: usize,
    /// 最大同時writeback数
    max_inflight_writeback: usize,

    // === Extent ===
    /// extent領域の総ブロック数（ディスク容量に応じて設定）
    extent_total_blocks: usize,

    // === Secondary ===
    secondary_index_buckets: usize,
    secondary_log_memory: usize,
    secondary_log_page_size_bits: u32,

    // === io_uring ===
    io_uring_queue_depth: u32,

    // === Compaction ===
    /// compactionのI/Oバジェット（同時in-flight数上限）
    compaction_io_budget: usize,
}
```

### 10.11 ディスクファイル構成

各コンポーネントは独立したファイルとして管理する。
これにより各コンポーネントを独立に拡張可能。

```
<data_dir>/
  hot_log.dat           // Primary Hot Log
  cold_log.dat          // Primary Cold Log
  cold_index_log.dat    // Cold-Log Index (hash chunk log)
  secondary_log.dat     // Secondary HybridLog
  extent_data.dat       // Extent領域（チャンクデータ）
```

各ファイルへのfdはKvs初期化時にopenし、Direct I/O (O_DIRECT) フラグで開く。
HybridLogの各インスタンスは対応するfdを保持する。
ExtentAllocatorはextent_data.datのfdを保持する。
