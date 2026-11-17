通行止め情報のページが更新されました。内容を確認し、必要なら `data/roads/` の設定を直して `python3 tools/road.py build` と `bundle` を実行し、Supabase で all-roads.sql を実行してください。

## 上野村 通行止めのお知らせ

- ページ：https://www.uenomura.jp/admin/life/seikatsu/road/tsukoudome.html
- 関係する林道の設定：`mikabo-super`、`yakyuzawa`、`ushiroyama`、`kamakake`、`ueno-otaki`

```diff
--- 前回
+++ 今回
@@ -3,3 +3,3 @@
 
-令和8年11月3日時点の通行止め情報となります。
+令和8年11月15日時点の通行止め情報となります。
 最新の状況はお問い合わせください。
@@ -23,3 +23,4 @@
 村道2206号線 【御巣鷹の尾根登山道方面】
-通行止めはありません
+冬季閉鎖に伴う通行止め
+期間：令和８年１１月１５日（日） ～ 令和９年４月２９日（金）予定
 村道1260号線 【須郷・楢沢方面】
```
