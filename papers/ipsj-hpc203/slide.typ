// main.typ — 20min / ~20 slides deck (研究報告用・文字多め)
// Compile: typst compile main.typ
#import "@preview/polylux:0.4.0": *

// ---------------- Meta ----------------
#let conf   = "IPSJ SIG TR 研究報告"
#let title  = "大規模高速ストレージ向け非同期RPC基盤の設計と評価"
#let author = "中野 将生, 建部 修見"
#let affil  = "筑波大学 計算科学研究センター"
#let date   = datetime.today().display()

//#show: slides.with(
//  theme: theme.light,
//  aspect: "16:9",
//  // 研究報告なのでフッタに情報密度を詰める
//  footer: box(fill: none)[#conf · #date],
//)

// ------------- Helpers (文字詰め向け) -----------------
// デフォルト文字サイズをやや小さめに
#set text(size: 28pt)

// 行間を詰めた箇条書き
#let dense(..items) = list(
  items,
  marker: "・",
  spacing: 0.25em,
  indent: 1.2em,
)

// 2段組スライド (左右に詰め込みたいとき用)
#let twocol(left, right) = grid(
  columns: (1fr, 1fr),
  gutter: 1.2em,
  left,
  right,
)

// 図用プレースホルダ
#let graph(path, caption: "") = {
  column(
    image(path, width: 100%),
    if caption != "" { text(size: 20pt, fill: gray)[#caption] }
  )
}

// セクション見出し用（大きめだが1行）
#let sec(title) = heading(level: 1)[#title]

// 小見出し
#let sub(t) = heading(level: 2)[#t]

// ---------------- Slides ----------------

// 1. Title
slide(
  layout: "title",
  title: title,
  subtitle: conf,
  authors: author,
  affiliation: affil,
  date: date,
  note: "自己紹介は最小限 (20s)"
)

// 2. アジェンダ
#slide[
  sec("アジェンダ")
  dense("背景・問題設定", "接続階層化の提案", "RPC 3方式の実装", "評価結果(3グラフ)", "考察・関連研究・今後")
]

// 3. 背景: HPC/LLMでのI/O集中
#slide[
  sec("背景: HPC/LLMでのI/O集中")
  dense(
    "大規模計算(数十~数百PB級FS)でメタ/データI/Oがボトルネック化",
    "学習/推論ワークロードでは同一チェックポイント/パラメータ群への同時アクセスが発生",
    "Burst Buffer, ad-hoc FSで一時的吸収は可能だが負荷はホットスポット化しやすい"
  )
]

// 4. 背景: RDMA/RCのスケール課題
#slide[
  sec("背景: RDMA RC接続のスケール課題")
  dense(
    "Reliable Connection(RC)はQP/CQ/RQ管理コストが接続数に比例",
    "RNR Retry Exceededなどの安定性問題",
    "数千〜万規模ノードでは全結合は非現実的"
  )
]

// 5. 問題設定
#slide[
  sec("問題設定")
  dense(
    "(1) ホットチャンク/ノード集中でサーバ側輻輳",
    "(2) RCの接続数増大でピーク性能が低下",
    "(3) 既存RPCは" + emph("非対称(多数Client/少数Server)想定") + "で本ケースに不適"
  )
]

// 6. 要件・設計方針
#slide[
  sec("要件・設計方針")
  dense(
    "各ノードの接続数をO(√n)程度に抑制しつつ高帯域・低遅延を維持",
    "データ/メタデータ整合性は軽量leaseで十分とする",
    "アプリ側APIは同期I/Oインターフェースを前提 (使いやすさ重視)"
  )
]

// 7. 提案: 接続階層化 (√n)
#slide[
  sec("提案: 接続階層化(√n)")
  dense(
    "全nノードを√n個グループ化し、各グループに中継ノードを配置",
    "各ノードは: グループ内(≈√n) + 中継(≈√n) + 自身で ≈3√n接続",
    "グループ内でホットスポットを局在化・分散"
  )
  rect(width: 100%, height: 30%, stroke: 1pt + gray)[概念図]
]

// 8. 一貫性: lease+キャッシュ戦略
#slide[
  sec("一貫性/キャッシュ戦略")
  dense(
    "IndexFS型lease: 読取多数/書込少数なFSメタデータに適合",
    "キャッシュ保持期間は短命、無効化はlease失効/更新で管理",
    "中継ノード経由でメタデータの整合性情報を伝搬"
  )
]

// 9. RPC方式の選択肢
#slide[
  sec("RPC方式: 3アプローチ")
  twocol(
    [
      sub("SEND")
      dense(
        "受信RQへ事前ポスト必須",
        "RNR回避には十分なバッファ数",
        "完了はCQポーリングで検知"
      )
      sub("WRITE + Immediate")
      dense(
        "相手メモリへ直接書込 + 32bit即値で識別",
        "RQ/CQ必要、実装はSEND近似",
        "本評価ではSENDとほぼ同性能"
      )
    ],
    [
      sub("WRITE + Polling")
      dense(
        "受信RQ不要。固定スロット化",
        "Seq番号をポーリングし到達確認",
        "RQ補充オーバーヘッド回避 → 低並列で優位"
      )
    ]
  )
]

// 10. 実装概要 (Rustランタイム)
#slide[
  sec("実装概要")
  dense(
    "Rust製軽量非同期ランタイム: CQポーリング専用スレッド/タスク",
    "1 QP = 1ユーザスレッド方針 (同期APIを自然に実装)",
    "固定長スロット/メモリプール化でalloc回避",
    "RNR Retry Timer=20µsなどNIC設定をチューニング"
  )
]

// 11. 実験環境
#slide[
  sec("実験環境")
  twocol(
    [
      sub("HW")
      dense(
        "Server CPU: AMD EPYC 9354P (32C)",
        "Client CPU: Intel Xeon Gold 6530",
        "NIC: NVIDIA ConnectX-7 (400GbE/IB)"
      )
    ],
    [
      sub("SW/条件")
      dense(
        "OFED 24.x, msg=256B req/resp",
        "各QP1並列 (多並列はRNRで不安定)",
        "再送/RNR設定を固定して比較"
      )
    ]
  )
]

// 12. 結果1: スループット
#slide[
  sec("結果1: スループット")
  graph("fig-throughput.pdf", caption: "QP数 vs Mrps")
  dense(
    "WRITE+Pollingが4096接続まで最速",
    "1200接続時でピーク比≈70% (RC劣化は許容範囲)",
    "64〜128QP付近を境に伸びが鈍化"
  )
]

// 13. 結果2: レイテンシ分布
#slide[
  sec("結果2: レイテンシ")
  graph("fig-latency.pdf", caption: "p50/p90/p99 レイテンシ")
  dense(
    "全方式でQP数に一次近似で増加",
    "WRITE系は初期立ち上がりが安定 (TLB/バッファ固定効果?)",
    "Polling方式でも分散は許容範囲"
  )
]

// 14. 結果3: CPU/オーバーヘッド
#slide[
  sec("結果3: CPU/オーバーヘッド")
  graph("fig-overhead.pdf", caption: "CPU占有率 / RQ管理コスト")
  dense(
    "PollingはCPUポーリング分上昇するが、総オーバーヘッドは低減",
    "SEND/IMMはRQ補充/取得がボトルネック",
    "方式ごとのCPU/メモリ使用量トレードオフを確認"
  )
]

// 15. 考察
#slide[
  sec("考察")
  dense(
    "Polling優位: RQ管理除去 & メモリローカリティ改善",
    "RC劣化は√n階層化で接続数自体を削減し吸収",
    "同期APIでも十分な性能を得る設計が実用上重要"
  )
]

// 16. 関連研究位置付け
#slide[
  sec("関連研究")
  dense(
    "FaSST/HERD: RDMA WRITE中心のキーバリューストア",
    "ScaleRPC: 大規模RPCフレームワーク (UD/DC等活用)",
    "IndexFS: leaseベース整合性; メタデータ分散",
    "本研究: RC維持+階層化で接続抑制に焦点"
  )
]

// 17. まとめ
#slide[
  sec("まとめ")
  dense(
    "√n階層化により各ノード接続数をO(√n)に削減",
    "RCでも1200接続でピーク70%性能を確認",
    "WRITE+Pollingが低並列RPCで最良。SEND/IMMは安定",
    "今後: マルチスレ化・他FS/ワークロード比較・実運用評価"
  )
]

// 18. 謝辞
#slide[
  sec("謝辞")
  text(size: 24pt)[JSPS科研費 JP22H00509 / NEDO JPNP20017 / JST CREST JPMJCR24R4 / CCS共同利用 / 富士通 特別共同研究]
]

// ---- Backup ----

#slide[
  sec("(Backup) SRQ不採用理由")
  dense("SRQ利用でRNR Retry Exceeded多発", "管理が複雑化し安定性を損ねる", "専用RQ採用で制御容易化")
]

#slide[
  sec("(Backup) 代替トランスポート")
  dense("UD: 接続数問題軽減も信頼性処理が必要", "DC/XRC: QP共有でスケールするが実装複雑", "本研究要件(同期I/O, RC互換)との整合性")
]

#slide[
  sec("(Backup) 実装詳細")
  dense("メモリ登録/固定バッファ割当の流れ", "CQポーリングループ擬似コード", "RNR/Timeout等エラー処理")
]
