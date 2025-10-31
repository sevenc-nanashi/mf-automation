# MoneyForward Automation

自分用のマネーフォワードの自動化スクリプト。
今のところPaseliの自動連携を実装。

## 環境変数

| 変数名                   | 説明                                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------------------- |
| `PASELI_ID`              | e-amusement pass に紐づく KONAMI ID                                                               |
| `PASELI_PASSWORD`        | KONAMI ID のパスワード                                                                            |
| `MONEYFORWARD_WALLET_ID` | マネーフォワードの対象ウォレットの ID。（URLの末尾の英数字列）                                    |
| `MONEYFORWARD_COOKIES`   | マネーフォワードのクッキーファイルへのパス（Docker では `/data/moneyforward.cookies.txt` に固定） |

## Docker

`docker-compose.yml` と `docker-entrypoint.sh` を用意しています：

1.  `moneyforward.cookies.txt` を `./cookies/` に配置します。（<https://addons.mozilla.org/ja/firefox/addon/export-cookies-txt/>）
2.  上記の環境変数を `.env` に記載します。
3.  イメージをビルド・起動します。

```bash
docker compose build
docker compose up -d
```
