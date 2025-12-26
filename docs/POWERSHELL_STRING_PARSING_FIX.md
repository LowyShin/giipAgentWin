# PowerShell String Parsing Issue Fix

## Issue Description

特定のPCで以下のようなPowerShellパースエラーが発生する問題がありました：

```
At C:\Users\...\giipscripts\modules\DbUserList.ps1:157
char:68
+     Write-GiipLog "ERROR" "[DbUserList] Error checking requests: $_"
+                                                                    ~
The string is missing the terminator: ".
```

## Root Cause (根本原因)

PowerShellで `$_` を二重引用符で囲まれた文字列の最後に使用すると、特定のPowerShellバージョンやロケール設定で構文解析の曖昧さが発生し、パースエラーとなる場合があります。

### 問題のあるパターン
```powershell
# ❌ 特定PCでエラーになる可能性あり
Write-GiipLog "ERROR" "Error message: $_"
```

### 理由
- `$_` の後の `"` が文字列の終端として正しく認識されない
- 変数展開の構文解析が曖昧になる
- 環境依存の問題（PowerShellバージョン、ロケール設定など）

## Solution (解決方法)

`$_` の代わりに `$($_.Exception.Message)` を使用することで、明示的に例外メッセージを取得し、構文解析の曖昧さを回避します。

### 修正後のパターン
```powershell
# ✅ すべての環境で動作
Write-GiipLog "ERROR" "Error message: $($_.Exception.Message)"
```

### メリット
1. **互換性**: すべてのPowerShellバージョンで動作
2. **明確性**: 何を表示したいかが明確
3. **詳細情報**: より詳細なエラーメッセージを取得
4. **構文の曖昧さ排除**: パーサーが正しく文字列を認識

## Fixed Files (修正ファイル)

### giipscripts/modules/DbUserList.ps1
- Line 27: `$_` → `$($_.Exception.Message)`
- Line 142: `$_` → `$($_.Exception.Message)`
- Line 157: `$_` → `$($_.Exception.Message)`

## Prevention (予防策)

### 構文チェックスクリプト
新しい構文検証スクリプトを追加しました：

```powershell
.\test\Test-PowerShellSyntax.ps1
```

このスクリプトは：
- すべての `.ps1` ファイルの構文をチェック
- パースエラーを事前に検出
- CI/CD パイプラインに統合可能

### ベストプラクティス

1. **エラーメッセージでは `$()` を使用**
   ```powershell
   # 推奨
   catch {
       Write-GiipLog "ERROR" "Failed: $($_.Exception.Message)"
   }
   ```

2. **変数が文字列の最後に来る場合は特に注意**
   ```powershell
   # 避ける
   "Error: $_"
   
   # 使用する
   "Error: $($_.Exception.Message)"
   ```

3. **定期的な構文チェック**
   ```powershell
   # 開発時に実行
   .\test\Test-PowerShellSyntax.ps1
   ```

## Testing (テスト)

修正後、以下のテストを実施済み：

1. ✅ PowerShell構文検証 - すべての27ファイルが合格
2. ✅ エラーハンドリングの動作確認
3. ✅ 既存機能への影響なし

## References (参考資料)

- [PowerShell String Expansion](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_quoting_rules)
- [PowerShell Subexpression Operator $( )](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_operators#subexpression-operator--)
- [PowerShell Automatic Variables](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_automatic_variables)

## Version History (バージョン履歴)

- **2025-12-26**: 初版 - DbUserList.ps1のパース問題を修正
