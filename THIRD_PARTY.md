# Ice由来の実装

参照したIceのコミットは `11edd39115f3f43a83ae114b5348df6a0e1741cf`。

- [MenuBarItemManager.swift](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift)：選択アイコンの移動、イベントのPID・セッション間配送、到達確認、カーソルの保存と復元。
- [ControlItem.swift](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/MenuBar/ControlItem/ControlItem.swift)：収納境界の幅を切り替える仕組み。
- [Bridging.swift](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Bridging/Bridging.swift)：メニューバーのウィンドウ列挙とフレーム取得。
- [Permission.swift](https://github.com/jordanbaird/Ice/blob/11edd39115f3f43a83ae114b5348df6a0e1741cf/Ice/Permissions/Permission.swift)：アクセシビリティは配置操作、画面収録は画像取得に使用する区別。

`Sources/ItemTransport.swift` と `Sources/IconMover.swift` はIceの移動処理を本アプリ向けに移植・整理したもの。元のIceはJordan Baird氏ほかによるGNU GPL v3のソフトウェア。ライセンス全文を `THIRD_PARTY/Ice-GPL-3.0.txt` に同梱する。これらを含む本アプリを配布する場合はGPL v3に従ってソースも提供する。

## 実装上の結論

収納は他アプリの設定値の上書きではない。対象ウィンドウをCommandドラッグ相当の操作で収納境界の左へ移動し、境界を広げて画面外へ退避させる。再表示では先に境界を縮め、元の隣接アイコンを基準に戻す。

Iceは単にマウスイベントを投稿して終わりにしない。nullイベントでPID側の経路を準備し、セッション側で実イベントを受信したことを確認してからPIDへ転送する。移動後の位置も確認する。カーソルは非表示にして保存位置へ戻し、失敗時もボタン解放と復元を行う。

画面収録は収納自体には使用しない。別のバーに実アイコン画像を表示する場合に必要な機能であり、今回の「選んだアイコンを隠す」実装には含めない。
