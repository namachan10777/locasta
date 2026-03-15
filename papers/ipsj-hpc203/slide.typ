// slide.typ — 20min / ~20 slides deck (HPC203 LocustaRPC)
// Compile: typst compile slide.typ
// Notes:  typst compile slide.typ --input notes=true

#import "@preview/touying:0.5.5": *
#import themes.university: *

// speaker-note表示モード（コマンドラインで --input notes=true を指定）
#let show-notes = sys.inputs.at("notes", default: "false") == "true"

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
  config-common(
    show-notes-on-second-screen: if show-notes { right } else { none },
  ),
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

  #speaker-note[
    発表の流れを説明します。
    まず背景としてFat-node化の流れとad-hocファイルシステムの必要性を述べ、
    RDMA接続状態の増大という問題設定を整理します。
    その後、提案の要点、設計詳細、実験結果、結論の順で進めます。
  ]
]

// ===== Part 1: 背景 =====

== 背景: リーダーシップマシンの動向

#slide[
  #set text(size: 0.9em)
  === エクサスケール時代のHPC
  #align(center)[
    #table(
      columns: (auto, auto, auto, auto, auto),
      stroke: 0.5pt,
      inset: 0.5em,
      [システム], [国], [性能], [ノード数], [構成],
      [Frontier], [米国], [1.2 EFLOPS], [9,408], [AMD MI250X],
      [El Capitan], [米国], [1.7 EFLOPS], [11,136], [AMD MI300A],
      [富岳], [日本], [0.44 EFLOPS], [158,976], [A64FX],
      [富岳NEXT], [日本], [—], [約3,000], [GPU搭載Fat-node],
    )
  ]

  - アクセラレータ中心の構成へ移行、ノード内共有メモリの強化が進む
  - ノード数は減少傾向だが、ノード内プロセス数は増加
  - 富岳NEXTでは100万オーダーのプロセス数を想定

  #speaker-note[
    リーダーシップマシンの動向を表で示します。
    Frontier、El Capitan、富岳といったエクサスケールシステムでは、
    アクセラレータを搭載したFat-node構成が主流です。
    富岳NEXTではGPU搭載Fat-nodeで約3,000ノード、100万オーダーのプロセス数が想定されています。
    ノード数は減少傾向ですが、ノード内プロセス数はむしろ増加しています。
  ]
]

== 背景: Fat-nodeとプロセス数増大

#slide[
  - ミドルウェアにはプロセス数に対するスケーラビリティが求められる
  - 処理性能の向上に伴い、よりスケーラブルなI/Oが常に要求される
  - MPIなど集団通信は最適化研究が進むが、ストレージミドルウェアでは通信相手を固定しにくい
  - 計算を補助するミドルウェアは少数CPU・小規模メモリで動作することが望ましい

  #align(center)[
    #box(stroke: 0.5pt, inset: 0.6em, radius: 4pt)[
      通信のスケーラビリティと省リソース化がミドルウェアの設計課題
    ]
  ]

  #speaker-note[
    Fat-node構成ではノード内プロセス数が増加するため、
    ミドルウェアにはプロセス数に対するスケーラビリティが求められます。
    MPIなどの集団通信は最適化研究が進んでいますが、
    ストレージミドルウェアではアクセス先の偏りや通信相手を固定しにくく、
    これらの最適化をそのまま適用することは困難です。
    また、計算を補助するミドルウェアは少数のCPU・小規模のメモリで動作することが望ましく、
    通信のスケーラビリティと省リソース化が設計課題となります。
  ]
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

  #speaker-note[
    並列ファイルシステムは専用ノード構成のため、大規模ジョブでは相対的に性能が低下します。
    また突発的なI/O集中や小粒度I/Oへの対応が困難です。
    この課題に対し、計算ノード上のNVMe SSDや永続メモリを活用するad-hocファイルシステムが発展してきました。
    図の右側に示すように、計算ノード上でファイルシステムデーモンが動作し、
    ノード数に比例して容量・帯域がスケールします。
  ]
]

== ad-hoc FSの通信課題

#slide[
  === 計算ノード上でクライアントとサーバが同居
  - 各ノードがFSデーモン（サーバ）とアプリプロセス（クライアント）を同時に実行
  - アクセス先はデータ配置で決まるため、全ノード対全ノードの通信が発生
  - 接続数はプロセス数 × ノード数に比例して増大

  #v(0.5em)

  === ad-hoc FSに求められる3要件
  + 既存アプリを活かすためのPOSIX互換インターフェース
  + 小粒度リクエストを処理する高メタデータ性能と低遅延通信
  + 計算用資源を圧迫しない省メモリ通信基盤

  #align(center)[
    #box(stroke: 0.5pt, inset: 0.5em, radius: 4pt)[
      本研究は3点目の通信資源効率に焦点を当てる
    ]
  ]

  #speaker-note[
    ad-hocファイルシステムの通信課題について説明します。
    ad-hoc FSでは計算ノード上にFSデーモンとアプリプロセスが同居するため、
    全ノード対全ノードの通信が発生し、接続数がプロセス数×ノード数に比例して増大します。
    ad-hoc FSに求められる要件は3つあります。
    POSIX互換インターフェース、高メタデータ性能と低遅延通信、そして計算資源を圧迫しない省メモリ通信基盤です。
    本研究は3点目の通信資源効率に焦点を当てています。
  ]
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

  #speaker-note[
    RDMAの接続形態にはRC、UD、DCがあります。
    RCは信頼性とone-sided通信が利点ですが、接続ごとに状態を保持するためcache thrashingが問題になります。
    UDはスケーラブルですがSEND/RECVのみで大容量転送に向きません。
    DCはNVIDIA独自拡張でRC相当の機能を持ちますが、NIC cache thrashingは根本的に解決しておらず、挙動もやや不安定です。
    本研究では、ノード内プロセスの通信をデーモンに集約することで、接続状態とメモリ消費を削減するアプローチを取ります。
  ]
]

== 提案の要点

#slide[
  - ノード外RDMA通信をデーモンに集約し、接続状態をプロセス数依存からデーモン数依存へ削減
  - Req/Resをリングバッファにバッチ化し、doorbell/CQ処理の固定コストを償却
  - 到着分散で崩れるバッチをAdaptive Batch Holdで再形成

  #speaker-note[
    提案手法の要点は3つあります。
    1つ目は、ノード外RDMA通信をデーモンに集約し、接続状態をαP個からD個へ削減することです。
    2つ目は、リクエストとレスポンスをリングバッファにバッチ化し、doorbellやCQ処理の固定コストを償却することです。
    3つ目は、ノード数増加で到着が分散しバッチが崩れる問題に対し、Adaptive Batch Holdで再形成することです。
  ]
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
      - リモート経路とローカル経路を分離
      - デーモンはペイロード非解釈、境界管理とWQE発行に専念
    ],
    [
      #figure(
        image("handmade-figures/in-node-architecture.drawio.pdf", width: 100%),
        caption: [ノード内アーキテクチャ],
      )
    ],
  )

  #speaker-note[
    提案アーキテクチャでは、ノード外通信の終端を通信デーモンに集約します。
    アプリケーションプロセスは共有メモリ経由でデーモンへ要求を委譲します。
    リモート経路とローカル経路を分離し、互いに干渉しない設計です。
    デーモンはペイロードの内容を解釈せず、境界管理とWQE発行に専念します。
  ]
]

== リモート経路の設計

#slide[
  #set list(spacing: 0.6em)
  === RDMA通信: クライアントがWQEを直接構築
  - クライアントが共有メモリ上の送信リングへ要求を直接書き込む
  - デーモンは書き込み済み範囲のWQEを構築しdoorbellを発行
  - ノード内コピーなし、デーモンはペイロードを解釈しない

  === 応答: 返信スロットによる完了通知
  - デーモンが受信した応答を対応する返信スロットへ書き戻す
  - クライアントは返信スロットの状態遷移をポーリングして完了を判定
  - call\_idとgenerationで要求と応答を対応付け

  === ローカルIPC: SPSCキュー
  - ローカル完結要求は専用SPSCキューで処理（リモート経路と分離）
  - 書き手と読み手が固定 → CAS不要、ポーリングのみで判定

  #speaker-note[
    リモート経路の設計を詳しく説明します。
    まずRDMA通信では、クライアントが共有メモリ上の送信リングへ要求を直接書き込みます。
    デーモンは書き込み済み範囲のWQEを構築してdoorbellを発行するだけで、ペイロードは解釈しません。
    応答はデーモンが対応する返信スロットへ書き戻し、クライアントはその状態遷移をポーリングして完了を判定します。
    call_idとgenerationにより要求と応答を対応付けます。
    ローカル完結要求は専用のSPSCキューで処理し、リモート経路と分離しています。
    書き手と読み手が固定されているためcompare-and-swapが不要で、ポーリングのみで判定できます。
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

  #speaker-note[
    RDMA通信プロトコルでは、送信リングと受信リングをペアで保持します。
    RDMA WRITE with Immediateを使い、複数メッセージをバッチ化して送信します。
    受信側はCompletion Queueのポーリングで到着を検知するため、バッファ全体の走査は不要です。
    これにより、通知処理コストをバッチ単位に償却できます。
  ]
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

  #speaker-note[
    複数プロセスが同一送信バッファへ同時に書き込むため、調停が必要です。
    2段階プロトコルを採用しています。
    第1段階でfetch_addにより書き込み領域を確保し、
    第2段階でheaderとpayloadを書き込んだ後、stateをReqReadyに更新して可視化します。
    デーモンはReqReadyが連続する区間をまとめてWQE化します。
    競合点をスロットのstate管理情報に限定することで、同期コストを最小化しています。
  ]
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

  #speaker-note[
    バッチ崩壊とは、CPUが空転しているにも関わらず性能が低下する現象です。
    ノード数増加でリクエスト到着が分散すると、1ループあたりの到着数が減少します。
    すると固定コストの償却が崩れ、さらにループが高速に回ることで到着数がさらに減る正のフィードバックが生じます。
    対策として、応答返却を短時間保持してバッチを再形成するAdaptive Batch Holdを導入しました。
    到着率からEWMAで保持時間を動的に推定し、到着がばらける時は保持を長く、集中時は短くする適応制御を行います。
  ]
]

// ===== Part 3: 関連研究 =====

== 関連研究

#slide[
  #set text(size: 0.9em)
  - *FaRM (NSDI14), eRPC (NSDI19), Flock(SOSP21)*: スレッド単位の最適化 → 複数プロセスの集約には適用できない
  - *ScaleRPC (EuroSys19)*: クライアント側負荷が高く、少数サーバ・多数クライアントモデル向け
  - *mRPC (NSDI23)*: 共有メモリ+サービス集約で最も近いが、非HPC向けで通信特性が異なる

  #v(0.5em)

  #align(center)[
    #box(stroke: 0.5pt, inset: 0.6em, radius: 4pt)[
      本研究: 複数プロセスの通信をデーモンへ集約し、通信資源の負荷を削減
    ]
  ]

  #speaker-note[
    関連研究との比較です。
    FaRM、eRPC、Flockはいずれもスレッド単位の最適化であり、複数プロセスの集約には適用できません。
    ScaleRPCはクライアント側の負荷が高く、少数サーバ・多数クライアントモデル向けです。
    mRPCは共有メモリとサービス集約を組み合わせており本研究に最も近いですが、
    クラウド・マイクロサービス向けであり、HPC環境とは通信特性が異なります。
    本研究の特徴は、HPC環境で複数プロセスの通信をデーモンへ集約し、通信資源の負荷を削減する点にあります。
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
    ],
  )

  #speaker-note[
    実験には筑波大学計算科学研究センターのPegasusクラスタを使用しました。
    CPUはIntel Xeon Platinum 8468の48コア、NICはConnectX-7、InfiniBand接続です。
    評価にはベンチマーク用KVSを実装し、YCSB-likeなread/write混合ワークロードで測定しました。
  ]
]

== 通信パターン

#slide[
  #grid(
    columns: (1fr, 1fr),
    gutter: 1.5em,
    [
      #image("handmade-figures/all-to-all.drawio.png", width: 85%)
    ],
    [
      === all-to-all KVS通信
      - 各クライアントが全ノードのKVSへGET/PUTを発行
      - アクセス先はキーのハッシュで決定 → 全ノードに分散
      - ad-hoc FSの実運用に近いアクセスパターン
      - direct connectionは提案と同一RPC実装で差分を「集約の有無」に限定
    ],
  )

  #speaker-note[
    通信パターンについて説明します。
    各クライアントプロセスが全ノードのKVSに対してGETとPUTを発行するall-to-all通信です。
    アクセス先はキーのハッシュで決定されるため、全ノードに分散します。
    これはad-hocファイルシステムの実運用に近いアクセスパターンです。
    比較用のdirect connectionは提案と同一のRPC実装を使い、ノード内集約の有無のみを差分としています。
  ]
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
      - ノード外接続数をデーモン数に抑制

      #v(0.5em)

      #box(stroke: 0.5pt, inset: 0.5em, radius: 4pt, width: 100%)[
        比較により通信経路（集約の有無）と\
        RPC実装差を分離して評価
      ]
    ],
  )

  #speaker-note[
    比較対象は3つです。
    UCXはHPCデファクトの通信ライブラリで、各クライアントが個別に通信コンテキストを持ちます。
    direct connectionは提案と同一のRPC実装ですが、ノード内集約を行わず各プロセスが直接通信します。
    これにより、UCXとの差分はRPC実装の違い、direct connectionとの差分は集約の有無に限定できます。
    LocustaRPCは提案方式で、共有メモリ経由でデーモンに委譲し、ノード外接続数をD個に抑制します。
  ]
]

== 結果1: UCX・direct connectionとの比較

#slide[
  #set text(size: 0.85em)
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
      === 条件
      - 3方式を同一KVSベンチマークで比較
      - Adaptive Batch Hold有効

      === 結果
      - 2-4ノード: 提案が優位だが、ローカル要求比率が高い条件
      - 8ノード: バッチ崩壊で11.2に低下
      - 16ノード: 19.6に回復するが依然ばらつき大
      - 32ノード: UCX 66.5 > direct 62.7 > 提案39.2
    ],
  )

  #speaker-note[
    3方式を同一KVSベンチマークで比較した結果です。Adaptive Batch Holdは有効にしています。
    2-4ノードでは提案方式が優位ですが、ローカル要求比率が高い条件での結果です。
    8ノードではバッチ崩壊で11.2MIOPSまで低下し、16ノードで19.6に回復しますが依然ばらつきが大きい状態です。
    32ノードではUCXが66.5、direct connectionが62.7に対し、提案方式は39.2と下回りました。
  ]
]

== 結果2: Adaptive Batch Holdの効果

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
      === 条件
      - 提案方式のみでBatch Hold有無を比較
      - 他の条件は結果1と同一

      === 結果
      - 8ノード: 8.26→11.18（1.35×）
      - 16ノード: 14.86→19.63（1.32×）
      - 32ノード: 27.25→39.24（1.44×）
    ],
  )

  #speaker-note[
    提案方式のみでAdaptive Batch Holdの有無を比較した結果です。他の条件は結果1と同一です。
    8ノードで1.35倍、16ノードで1.32倍、32ノードで1.44倍の改善を確認しました。
    中大規模条件でバッチ崩壊を緩和できることが分かります。
  ]
]

// ===== Part 5: まとめ =====

== まとめ

#slide[
  === 達成した成果
  - ノード内共有メモリによる要求委譲+デーモン通信集約のRPC基盤を設計・実装
  - 接続管理コストをプロセス数依存からデーモン数依存に削減し、通信資源効率改善の方向性を示した
  - Adaptive Batch Holdで中大規模のバッチ崩壊を最大1.44×緩和

  #v(0.5em)

  === 今後の課題
  - ミドルウェア一貫性設計によりQueue Depthの向上が必要

  #speaker-note[
    まとめです。
    ノード内共有メモリによる要求委譲とデーモン通信集約のRPC基盤を設計・実装しました。
    接続管理コストをαPからDに削減し、通信資源効率改善の方向性を示しました。
    Adaptive Batch Holdで中大規模のバッチ崩壊を最大1.44倍緩和できることを確認しました。
    今後の課題として、ミドルウェアの一貫性設計によりQueue Depthを向上させる必要があります。
  ]
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

  #speaker-note[
    RDMAのキュー操作の詳細です。
    SQとRQの対がQueue Pairを構成します。
    Work Requestを投稿するとNICがWork Queue Elementとして処理し、
    完了通知はCompletion Queueに集約されます。
    doorbell batchingで複数WQEをまとめて通知することでPCIeトランザクションを削減し、
    unsignaled CQEでCQ処理負荷を削減できます。
  ]
]

== (Backup) RDMAトランスポート比較

#slide[
  - *RC*: 信頼性・順序性・one-sided通信 / 接続ごとに状態保持 → cache thrashing
  - *UD*: 単一ハンドラで多数通信 / SEND/RECVのみ、MTU制限
  - *DC*: RC相当+接続数スケール（NVIDIA独自）/ 多数同時通信で性能低下

  #speaker-note[
    RDMAトランスポートの比較です。
    RCは信頼性と順序性、one-sided通信が利点ですが、接続ごとに状態を保持するためcache thrashingが問題です。
    UDは単一ハンドラで多数と通信可能ですが、SEND/RECVのみでMTU制限があります。
    DCはRC相当の機能で接続数に対してスケールしますが、NVIDIA独自で多数同時通信時に性能低下があります。
  ]
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

  #speaker-note[
    Batch Hold改善率の全数値です。
    4ノードではわずかに低下していますが、これは到着が十分集中しておりholdが不要な条件だからです。
    8ノード以上では顕著な改善が見られ、バッチ崩壊緩和の効果を確認できます。
  ]
]
