// slide.typ — 20min / ~20 slides deck (HPC203 LocustaRPC)
// Compile: typst compile slide.typ

#import "@preview/touying:0.5.5": *
#import themes.university: *

// テーマ設定
#show: university-theme.with(
  aspect-ratio: "16-9",
  config-info(
    title: [LocustaRPC: 次世代リーダーシップマシンのための\ スケーラブルなRPC基盤],
    short-title: [LocustaRPC],
    subtitle: [IPSJ SIG HPC 203 研究報告],
    author: [中野 将生, 前田 宗則, 建部 修見],
    date: [2026年3月],
    institution: [筑波大学 計算科学研究センター / 富士通株式会社],
  ),
  config-page(margin: (top: 2.5em, bottom: 2em, x: 2em)),
  config-methods(init: (self: none, body) => {
    set text(font: ("Hiragino Kaku Gothic ProN", "Hiragino Kaku Gothic Pro", "BIZ UDGothic"), lang: "ja", size: 20pt)
    set par(leading: 0.9em)
    set list(spacing: 1.2em)
    set enum(spacing: 1.2em)
    body
  }),
)

// ===== タイトルスライド =====
#title-slide()

// ===== 目次 =====
== 目次

#slide[
  + 背景: Fat-node化とad-hoc FS
  + 問題設定: RDMA接続状態の増大
  + 提案の要点: ノード内集約とバッチ制御
  + 設計詳細: 通信プロトコルと制御
  + 実験: KVSベンチマーク評価
  + 結論: 効果と制約
]

// ===== Part 1: 背景 =====

== 背景: Fat-nodeとプロセス数増大

#slide[
  - アクセラレータ中心の構成へ移行、ノード内共有メモリの強化が進む
  - El Capitan, Frontier, 富岳NEXT: Fat-node構成が主流に
  - ノード数は減少傾向だが、ノード内プロセス数は増加
  - 富岳NEXTでは100万オーダーのプロセス数を想定
  - ミドルウェアにはプロセス数に対するスケーラビリティが求められる
  - 処理性能の向上に伴い、よりスケーラブルなI/Oが常に要求される
]

== 背景: ad-hocファイルシステム

#slide[
  #grid(
    columns: (1fr, 1fr),
    gutter: 1.5em,
    [
      - PFSは専用ノード構成 → 大規模ジョブで相対的性能低下
      - 突発的I/O集中・小粒度I/Oへの対応が困難
      - 計算ノード上NVMe/PMを活用するad-hoc FSが発展
      - CHFS, GekkoFS, BurstFS等
    ],
    [
      #align(center)[
        #figure(
          image("handmade-figures/pfs-and-adhocfs.drawio.pdf", width: 100%),
          caption: [PFS vs ad-hoc FS],
        )
      ]
    ],
  )
]

== 問題設定: RDMA接続状態の増大

#slide[
  #set text(size: 0.95em)
  - RC: 信頼性・one-sided通信が可能だが接続ごとに状態保持 → cache thrashing
  - UD: スケーラブルだがSEND/RECVのみ、大容量転送に不向き
  - DC: NVIDIA独自拡張、RC相当だがNIC cache thrashingは未解決・挙動がやや不安定

  #v(0.5em)

  #align(center)[
    #box(stroke: 1pt, inset: 0.8em, radius: 4pt, fill: rgb("#f0f0f0"))[
      *本研究の焦点*: ノード内プロセスの通信をデーモンに集約し、接続状態とメモリ消費を削減
    ]
  ]
]

== 提案の要点

#slide[
  - ノード外RDMA通信をデーモンに集約し、接続状態を$alpha P$から$D$へ削減
  - Req/Resをリングバッファにバッチ化し、doorbell/CQ処理の固定コストを償却
  - 到着分散で崩れるバッチをAdaptive Batch Holdで再形成

]

// ===== Part 2: 設計 =====

== 設計: ノード内集約アーキテクチャ

#slide[
  #grid(
    columns: (1fr, 1fr),
    gutter: 1.5em,
    [
      - ノード外通信の終端をデーモンに集約
      - アプリプロセスは共有メモリIPCで要求委譲
      - 要求キュー + 応答スロットで構成
      - ローカル要求は専用IPCキューで処理（リモート経路と分離）
      - デーモンはペイロード非解釈、境界管理とWQE発行に専念
    ],
    [
      #figure(
        image("handmade-figures/in-node-architecture.drawio.pdf", width: 100%),
        caption: [ノード内アーキテクチャ],
      )
    ],
  )
]

== QP状態メモリの見積り

#slide[
  - UCX: $M_"conn" = alpha P (N-1)(m_"qp" + m_"ctl")$ ← プロセスごとに接続
  - 提案: $M_"conn" = D (N-1)(m_"qp" + m_"ctl")$ ← デーモンに集約
  - 改善率 = $alpha P \/ D$

  #v(0.5em)

  #text(size: 0.85em)[
    例: N=256, P=64, D=8, $m_"qp"$=16KiB \
    → UCX ≈ 255MiB vs 提案 ≈ 32MiB（約8倍削減） \
    → $alpha$=P構成では約512倍削減
  ]

  #v(0.3em)

  #align(center)[
    #box(stroke: 0.5pt, inset: 0.5em, radius: 4pt)[
      NIC接続状態キャッシュ競合の緩和にも寄与
    ]
  ]
]

== RDMA通信プロトコル

#slide[
  #grid(
    columns: (1fr, 1fr),
    gutter: 1.5em,
    [
      - 送信リングと受信リングをペアで保持
      - RDMA WRITE with Immediateでメッセージをバッチ化して送信
      - 受信側はCQポーリングで到着検知（バッファ走査不要）
      - 通知コストをバッチ単位に償却
    ],
    [
      #figure(
        image("handmade-figures/ringbufrpc.drawio.pdf", width: 100%),
        caption: [送信リング/受信リングのペア構成],
      )
    ],
  )
]


== 送信バッファ書き込み調停

#slide[
  #grid(
    columns: (1fr, 1fr),
    gutter: 1.5em,
    [
      === 2段階プロトコル
      - 複数プロセスが同一バッファへ同時書き込み
      + fetch\_addでproducer位置を確保
      + header+payload書込後、stateをReqReadyへ更新
      - デーモンはReqReady連続区間をWQE化
      - 競合点を管理情報に限定
    ],
    [
      #figure(
        image("handmade-figures/message-write.drawio.pdf", width: 100%),
        caption: [協調書き込みプロトコル],
      )
    ],
  )
]

== Adaptive Batch Hold制御

#slide[
  === バッチ崩壊の問題
  - CPUが空転しているにも関わらず性能が低下する現象
  - ノード数増加でリクエスト到着が分散 → 1ループあたり到着数減少
  - 固定コスト（CQポーリング, IPCチェック）の償却が崩れる
  - 小バッチ → ループ高速化 → さらに到着少 → 正のフィードバックで性能低下

  #v(0.5em)

  === 対策: Adaptive Batch Hold
  - 応答返却を短時間保持してバッチ再形成
  - 到着率から $T_"hold"$ をEWMAで動的推定
  - 到着ばらけ時は保持長く、集中時は短く → 適応制御
  // TODO: バッチ崩壊の概念図（正フィードバックループ）があると効果的 → ユーザに作成依頼
]

// ===== Part 3: 関連研究 =====

== 関連研究

#slide[
  #set text(size: 0.9em)
  - *FaRM, eRPC, Flock*: スレッド単位の最適化 → 複数プロセスの集約には適用できない
  - *ScaleRPC*: クライアント側負荷が高く、少数サーバ・多数クライアントモデル向け
  - *mRPC*: 共有メモリ+サービス集約で最も近いが、非HPC向けで通信特性が異なる

  #v(0.5em)

  #align(center)[
    #box(stroke: 0.5pt, inset: 0.6em, radius: 4pt)[
      本研究: 複数プロセスの通信をデーモンへ集約し、通信資源の負荷を削減
    ]
  ]
]

// ===== Part 4: 実験 =====

== 実験環境・手法

#slide[
  #grid(
    columns: (1fr, 1fr),
    gutter: 1.5em,
    [
      === 環境
      #align(center)[
        #table(
          columns: (auto, 1fr),
          stroke: 0.5pt,
          inset: 0.5em,
          [クラスタ], [Pegasus（筑波大CCS）],
          [CPU], [Intel Xeon Platinum 8468 (48C)],
          [NIC], [Mellanox ConnectX-7],
          [ネットワーク], [InfiniBand],
          [NUMA], [1ノード構成、コア0-1はIRQ専用],
        )
      ]
    ],
    [
      === 手法
      - ベンチマーク用KVS（rank id+ユーザキー）
      - YCSB-like read/write混合（50/50）
      - クライアントプロセス数を変化させ評価
      - 指標: スループット（MIOPS）

      #v(0.5em)

      #box(stroke: 0.5pt, inset: 0.5em, radius: 4pt, width: 100%)[
        direct connectionは提案と同一RPC実装で\
        差分を「ノード内集約の有無」に限定
      ]
    ],
  )
]

== 比較対象

#slide[
  #grid(
    columns: (1fr, 1fr),
    gutter: 1.5em,
    [
      === UCX（ベースライン）
      - 各クライアントが個別に通信コンテキスト保持
      - Active Message APIで直接通信
      - HPCデファクトの通信ライブラリ

      #v(0.5em)

      === direct connection
      - 提案と同一RPC実装
      - ノード内集約なし（各プロセスが直接通信）
      - 集約の有無のみの差分を分離
    ],
    [
      === LocustaRPC（提案）
      - 共有メモリ経由でデーモンに委譲
      - デーモンがRDMA通信を集約
      - ノード外接続数を$D$に抑制

      #v(0.5em)

      #box(stroke: 0.5pt, inset: 0.5em, radius: 4pt, width: 100%)[
        比較により通信経路（集約の有無）と\
        RPC実装差を分離して評価
      ]
    ],
  )
]

== 結果1: 基本性能

#slide[
  #grid(
    columns: (1.2fr, 1fr),
    gutter: 1em,
    [
      #figure(
        image("figures/kvs_benchmark_throughput.pdf", width: 100%),
        caption: [ノード数 vs 総スループット（MIOPS）],
      )
    ],
    [
      === 結果
      - 2-4ノード: 提案が優位だが、ローカル要求比率が高い条件
      - 8ノード: バッチ崩壊で11.2に低下
      - 16ノード: 19.6に回復するが依然ばらつき大
      - 32ノード: UCX 66.5 > direct 62.7 > 提案39.2
    ],
  )
]

== 結果2: Adaptive Batch Hold評価

#slide[
  #grid(
    columns: (1.2fr, 1fr),
    gutter: 1em,
    [
      #figure(
        image("figures/kvs_benchmark_batch_hold.pdf", width: 100%),
        caption: [Batch Hold有無の比較],
      )
    ],
    [
      === 結果
      - 8ノード: 8.26→11.18（1.35×）
      - 16ノード: 14.86→19.63（1.32×）
      - 32ノード: 27.25→39.24（1.44×）

      #v(0.3em)

      #box(stroke: 0.5pt, inset: 0.5em, radius: 4pt)[
        中大規模でバッチ崩壊は緩和できるが\
        1-hop追加そのもののコストは残る
      ]
    ],
  )
]

== 解釈と制約

#slide[
  - 小規模（2-4ノード）の優位は、ローカル通信で終了する要求が多いことの寄与が大きい
  - リモート通信では、ノード内委譲→デーモン送信の1-hop追加が固定オーバーヘッドとなる
  - Adaptive Batch Holdは中大規模のバッチ崩壊を緩和するが、逐次RPCの応答待ち自体は残る
  - POSIX系ワークロードでは逐次依存が強く、応答待ちのレイテンシを隠しにくい
  - 32ノードでは追加hopとデーモン並列度の両方が律速となり、UCX/directを下回る
  - 接続状態メモリ削減の方向性は有効だが、性能改善にはad-hoc FS側の意味論設計も必要

  #v(0.5em)

  #box(stroke: 0.5pt, inset: 0.5em, radius: 4pt, width: 100%)[
    結論: 単純なRPC集約だけでは不十分で、\
    応答待ちを減らせるad-hoc FSの意味論設計まで含めた最適化が必要
  ]
]

// ===== Part 5: まとめ =====

== まとめ

#slide[
  === 達成した成果
  - ノード内共有メモリによる要求委譲+デーモン通信集約のRPC基盤を設計・実装
  - 接続管理コストを$alpha P$→$D$に削減し、通信資源効率改善の方向性を示した
  - 小規模での性能優位はローカル要求比率の高さに支えられることを確認
  - Adaptive Batch Holdで中大規模のバッチ崩壊を最大1.44×緩和
  - 一方で、POSIX的な逐次RPCでは追加hopのレイテンシ影響が大きい

  #v(0.5em)

  === 今後の課題
  + 応答待ちなしで次操作を発行可能にするad-hoc FS意味論の再設計
  + 中継時の1-hop追加コストを抑えるIPC/送信経路の再設計
  + デーモン並列度の拡張による大規模時の律速緩和
  + DCを用いたSQ/送受信キュー管理の一本化
  + 実ad-hocファイルシステム上での大規模評価
]

== 謝辞

#slide[
  - JSPS科研費 JP22H00509
  - NEDO JPNP20017
  - JST CREST JPMJCR24R4
  - 筑波大学計算科学研究センター 学際共同利用プログラム
  - 富士通株式会社 特別共同研究
]

// ===== 予備スライド =====

== (Backup) RDMAキュー操作

#slide[
  #grid(
    columns: (1fr, 1fr),
    gutter: 1.5em,
    [
      - SQ+RQの対 = Queue Pair（QP）
      - Work Request（WR）→ Work Queue Element（WQE）
      - 完了通知はCompletion Queue（CQ）に集約
      - doorbell batching: 複数WQEをまとめて通知
      - unsignaled CQE: CQ処理負荷の削減
    ],
    [
      #figure(
        image("handmade-figures/RDMA-SQ-and-RQ.drawio.pdf", width: 100%),
        caption: [SQ, RQ, QPの関係],
      )
    ],
  )
]

== (Backup) RDMAトランスポート比較

#slide[
  - *RC*: 信頼性・順序性・one-sided通信 / 接続ごとに状態保持 → cache thrashing
  - *UD*: 単一ハンドラで多数通信 / SEND/RECVのみ、MTU制限
  - *DC*: RC相当+接続数スケール（NVIDIA独自）/ 多数同時通信で性能低下
]

== (Backup) Batch Hold改善率詳細

#slide[
  #align(center)[
    #table(
      columns: (auto, auto, auto, auto),
      stroke: 0.5pt,
      inset: 0.6em,
      [ノード数], [no batch hold], [batch hold（10µs）], [改善率],
      [2],  [13.97], [14.86], [1.06×],
      [4],  [22.11], [21.10], [0.95×],
      [8],  [8.26],  [11.18], [1.35×],
      [16], [14.86], [19.63], [1.32×],
      [32], [27.25], [39.24], [1.44×],
    )
  ]

  - 4ノードではわずかに低下 → 到着が十分集中しておりhold不要
  - 8ノード以上で顕著な改善 → バッチ崩壊緩和の効果
]
