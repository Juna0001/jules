# XAUUSD / XAGUSD ペアトレードEA（自動売買システム）仕様書

本仕様書は、金（XAUUSD）と銀（XAGUSD）の価格比率（Gold-Silver Ratio, GSR）を用いた統計的裁定取引（Statistical Arbitrage）を行うMT5用EA（Expert Advisor）の要件定義書です。

## 1. 戦略概要 (Strategy Overview)

**コンセプト:**
金と銀の強い正の相関を利用し、両者の価格比率（GSR = XAUUSD / XAGUSD）が平均から乖離したタイミングでエントリーし、平均に戻ったタイミングで決済する「平均回帰（Mean Reversion）」戦略です。
市場全体の方向性（上昇・下落）に関わらず、二つの資産の相対的な価格差から利益を得るマーケットニュートラルな運用を目指します。

## 2. パラメータ設定 (Input Parameters)

ユーザーが調整可能な主なパラメータは以下の通りです。

| パラメータ名 | デフォルト値 | 説明 |
| :--- | :--- | :--- |
| `MagicNumber` | 123456 | EAのマジックナンバー |
| `XAU_Symbol` | "XAUUSD" | 金のシンボル名（ブローカーにより異なる場合に対応） |
| `XAG_Symbol` | "XAGUSD" | 銀のシンボル名 |
| `Base_Lot_XAU` | 0.01 | 金（XAUUSD）の基準ロット数 |
| `MA_Period` | 20 | GSRの移動平均を算出する期間（日足推奨） |
| `BB_Deviation` | 2.0 | エントリー判定に用いる標準偏差（σ）の倍率 |
| `Max_Deviation` | 4.0 | 損切り判定に用いる標準偏差（σ）の倍率（最大許容乖離） |
| `Slippage` | 3 | 許容スリッページ（ポイント） |

## 3. ロジック詳細 (Logic Details)

### 3.1. データの計算 (Calculation)

毎ティック（または足の確定時）に以下の値を計算します。

1.  **GSR（現在値）:** `Current_GSR = Price(XAUUSD) / Price(XAGUSD)`
2.  **GSRの移動平均（MA）:** 指定期間（`MA_Period`）におけるGSRの単純移動平均
3.  **GSRの標準偏差（SD）:** 指定期間（`MA_Period`）におけるGSRの標準偏差
4.  **アッパーバンド:** `Upper_Band = MA + (SD * BB_Deviation)`
5.  **ロワーバンド:** `Lower_Band = MA - (SD * BB_Deviation)`

### 3.2. ロット数の計算 (Position Sizing)

市場中立（ドル・ニュートラル）を保つため、銀のロット数は金の保有金額と等価になるように自動調整します。

*   **XAU保有額:** `Value_XAU = Base_Lot_XAU * Price(XAUUSD) * Contract_Size_XAU`
*   **XAGロット数:** `Lot_XAG = Value_XAU / (Price(XAGUSD) * Contract_Size_XAG)`
    *   ※計算結果はブローカーの最小ロット単位（Step）に合わせて丸める必要があります。

### 3.3. エントリー条件 (Entry Logic)

ポジションを持っていない状態で、以下の条件を満たしたときにエントリーします。

*   **売りシグナル（GSRが割高 = 金が割高 / 銀が割安）**
    *   条件: `Current_GSR > Upper_Band`
    *   アクション: **XAUUSD 売り（Sell）** かつ **XAGUSD 買い（Buy）**

*   **買いシグナル（GSRが割安 = 金が割安 / 銀が割高）**
    *   条件: `Current_GSR < Lower_Band`
    *   アクション: **XAUUSD 買い（Buy）** かつ **XAGUSD 売り（Sell）**

### 3.4. エグジット条件 (Exit Logic)

保有ポジションに対して、以下の条件を満たしたときに全決済（Close All）します。

*   **利確（平均回帰完了）**
    *   条件: `Current_GSR` が `MA` に到達（クロス）したとき。
    *   解説: 乖離が解消された時点で、理論上の利益が発生しているはずです。

*   **損切り（乖離拡大）**
    *   条件: `Current_GSR` が `MA` から `SD * Max_Deviation` 以上離れたとき。
    *   解説: 相関関係が一時的に崩壊している可能性があるため、損失拡大を防ぐために撤退します。

## 4. エラー処理と安全対策 (Safety & Error Handling)

*   **同期エントリー:** XAUUSDとXAGUSDの注文は可能な限り同時に送信します（`OrderSendAsync`の利用を検討）。片方だけ約定してしまった場合は、即座にもう片方を成行で注文するか、両方決済するロジックを組み込みます。
*   **スプレッドフィルター:** 両銘柄のスプレッドが指定値以上に拡大している場合（早朝や指標発表時など）はエントリーを見送ります。
*   **証拠金チェック:** エントリー前に十分な余剰証拠金があるか確認します。

## 5. バックテスト時の注意点

*   MT5のストラテジーテスターでは「複数通貨ペア」のバックテストが可能ですが、`OnTick` 関数はチャートを開いている通貨ペア（通常はXAUUSD）のティックでしか動作しません。
*   XAGUSDの価格データも同時に読み込むために、`iClose` や `SymbolInfoDouble` などの関数で適切にデータを取得する必要があります。
