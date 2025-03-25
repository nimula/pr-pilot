# PR Pilot

一套用於自動化 GitHub PR 創建和管理的 Shell 腳本工具。

## 功能

- AI 驅動的 PR 標題生成（使用 OpenAI API）
- 自動產生 PR 和指定標籤
- 整合 Gemini Code Assist 的程式碼摘要

## 前置需求

- GitHub CLI (`gh`)
- `jq` 用於處理 JSON
- OpenAI API 金鑰（可選，用於 AI 標題建議）

## 安裝

1. 克隆此儲存庫
   ```bash
   git clone [repository-url]
   ```

2. 使腳本可執行
   ```bash
   chmod +x create_pr.sh gemini_finder.sh
   ```

3. 設置 OpenAI API 金鑰（可選）
   ```bash
   export OPENAI_API_KEY='your-api-key'
   ```

## 使用方法

### 創建 PR

```bash
./create_pr.sh [PR標題] [PR描述] [目標分支] [標籤]
```

選項：
- PR 標題（可選）：如果未提供將自動生成
- PR 描述（可選）：PR 的描述內容
- 目標分支（可選，預設：main）：PR 的目標分支
- 標籤（可選，預設：type: feature）：PR 的標籤

### 使用 Gemini 審查摘要更新 PR

```bash
./gemini_finder.sh [PR編號]
```

選項：
- PR 編號：要更新的 PR 編號

## 功能詳細說明

### create_pr.sh

- 從提交訊息自動檢測變更類型
- 使用 AI 生成 PR 標題（如果有 OpenAI API 金鑰）
- 支援帶有 AI 建議的手動標題輸入
- 處理未提交的更改
- 自動添加適當的標籤

### gemini_finder.sh

- 尋找 Gemini 的程式碼審查評論
- 提取「Summary of Changes」部分
- 使用摘要更新 PR 描述
- 維持正確的格式

## 標籤

- `type: feature` - 新功能
- `type: bug(fix)` - 錯誤修復
- `type: docs` - 文檔更改
- `type: refactor` - 程式碼重構
- `type: chore` - 維護任務

## 貢獻

歡迎提交問題和改進建議！

## 授權

MIT 授權

---
[English Documentation](../README.md) 
