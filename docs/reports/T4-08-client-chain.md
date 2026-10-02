# T4-08: 3サービス間のクライアント・OTLP検証

2026-10-02、Linux上でNativeのクライアントE2E 6ケースと、OTelのHTTP E2E 3ケースがすべて成功した。
Masterで定義したクライアントのWorker別チャネル生成、3サービス間の期限・メタデータ伝播、実HTTP経由のトレース連結とメトリクス集計を確認した。
この記録は計9ケースの検証結果を扱う。リポジトリ全体のテスト・カバレッジ・性能評価は含まない。

## 実行環境と再現コマンド

| 項目 | 検証時の値 |
| --- | --- |
| OS / CPU | Debian 13.7、Linux 6.8.0-117-generic、aarch64 |
| Ruby / grpc | 3.4.11 / 1.83.0 |
| 開発中のGem | gritz-core 0.4.0、gritz-native 0.4.0、gritz-otel 0.1.0 |
| Trace SDK / API / HTTP exporter | 1.13.1 / 1.11.1 / 0.35.1 |
| Metrics SDK / HTTP exporter | 0.19.0 / 0.13.0 |
| Native E2E | 6 examples、0 failures、5.31秒 |
| OTel E2E | 3 examples、0 failures、3.89秒 |

実行には、3つのGemをローカルの`path`依存にした検証用Bundleを使った。
以下は既存のLinuxコンテナ`gritz-t2-test`で実行したコマンドである。
`tmp/phase2.Gemfile`は検証用の非公開ファイルで、名前は以前のPhaseから引き継いでいる。
再現時には同じ3つのGemとRSpecを含むBundleを準備し、`BUNDLE_GEMFILE`をそのパスに置き換える。

```sh
docker exec -e BUNDLE_GEMFILE=/workspace/gritz-native/tmp/phase2.Gemfile \
  -w /workspace/gritz-native gritz-t2-test \
  bundle exec rspec spec/integration/client/chain_spec.rb

docker exec -e BUNDLE_GEMFILE=/workspace/gritz-native/tmp/phase2.Gemfile \
  -w /workspace/gritz-otel gritz-t2-test \
  bundle exec rspec spec/integration/client/otlp_chain_spec.rb
```

## Master定義から送信側Workerの3チャネルを生成

各ケースは独立したRuby subprocessでA・B・Cの3サービスを起動する。
Aは2 Worker、BとCは各1 Workerの構成で、A→B→Cへ実際のUnary RPCを送る。
RSpec親プロセスの初期化済みgRPCリソースはforkしない。

Native E2Eでは、設定ファイルを読む親で`Gritz::Client.define`を実行してもチャネルが生成されないことを確認した。
その後、Aの両WorkerとBのWorkerを実際に呼び出し、`GRPC::Core::Channel.new`の記録から、送信側Workerごとに1チャネル、計3チャネルを確認した。
Cには下流呼び出しがない。チャネルの生成PID・接続先・`pick_first`サービス設定も照合した。

3つのサーバで受信した絶対期限は下流へ進むたびに短縮され、短い親の期限も安全余白付きで反映された。
`x-request-id`と`traceparent`は連結し、`authorization`は下流にコピーされなかった。
リッチな下流エラーについては、未処理時の安全な`INTERNAL`、型付きrescueでの詳細デコード、明示的なpassthroughでの元のコード・詳細・trailer保持を別々に検証した。

## 4 WorkerだけでSDKを起動し、5 Spanを連結

[OTel E2E](../../spec/integration/client/otlp_chain_spec.rb)は公開DSLの`opentelemetry { |sdk| ... }`を使う。
設定を読むMasterではSDKが未ロードで、BatchSpanProcessorのThreadも0だった。
4 Workerすべての起動記録にはSDK初期化とBatchSpanProcessorのThread 1つがあり、最初のRPC前に下流チャネルは生成されていなかった。

1回の成功RPCから、同一のtrace IDを持つ5 Spanを受信した。
Spanの親子関係は次の順序で、先頭のA serverは外部から渡した親Span IDに接続していた。

```text
A server → A client → B server → B client → C server
```

B・Cへ渡る`traceparent`には、それぞれ直前のclient Span IDが入っていた。
各Spanの`service.name`、`process.pid`、`service.instance.id`を、RPCを処理したWorkerのPIDと照合した。
RPCのサービス名・メソッド名・成功ステータスも検証した。

## 実HTTPのメトリクス件数と全プロセスの終了を照合

[テスト用Collector](../../spec/integration/client/support/otlp_collector.rb)はTCPServerで`/v1/traces`と`/v1/metrics`を受け取り、gzipを展開して公式OTLP protobufをデコードする。
Trace・Metricsとも公式HTTP exporterからのgzip送信を確認した。
Collectorを含むfixtureと生成済みprotobufはこのリポジトリ内にあり、他リポジトリのspecを参照しない。

メトリクスのケースでは4 WorkerすべてがRPCを処理するまで実リクエストを送り、レスポンス中のPIDからWorker別の件数を数えた。
`gritz.rpc.server.duration`の累積histogram countはWorker別の実処理件数と一致し、その合計も各サーバの受信記録数と一致した。
全4 Workerの実際のRSS gaugeもHTTP経由で受信した。
件数は接続の分散により実行ごとに変わるため、固定値との比較ではなく、その実行で観測した件数と照合する。

各ケースの終了時にはLauncher・Master・Workerの所有PIDを保存し、停止後の成功終了と、全PIDが`kill(0)`で`ESRCH`になることを確認した。
Collectorの受信Threadも終了する。

今回の対象はローカル通信の短いUnary RPCであり、ストリーミング負荷や長時間のCollector障害はこの9ケースの評価範囲に含まれない。
Phase 4のクライアント・伝播の完了条件はこの構成で確認できた。新Gem`gritz-otel`の初回公開は、ユーザーの指定どおり公開直前に止め、オーナーへ依頼する。
