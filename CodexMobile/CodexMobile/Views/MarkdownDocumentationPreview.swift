#if DEBUG && targetEnvironment(simulator)
// Fictional content shared by both provider previews; no live session or model.
enum MarkdownDocumentationSample {
    static let prompt = "请说明示例待办 App 的修改建议。"
    static let answer = """
    ### 修改建议

    普通正文：**重点文字恢复为黑色／白色加粗**，继续保留行内代码和 Markdown 排版。

    **1. 先确认 `todo_list_empty_state_before_save` 的行为。**

    **示例目录是 `/Users/example`，请核对项目位置。**

    - **空列表**：显示简短的引导文案，保留添加按钮。
    - **已有内容**：继续显示原来的待办，不清空用户数据。
    - 路径 `/Users/example/Documents/Project/TodoDemo` 应在手机宽度内自动换行。

    **2. 保留原有数据。**

    1. 检查首次打开与清空列表两种情况。
    2. 核对结果，再保存修改。

    > 示例提示：完成检查后，可以继续同一个会话。

    ```swift
    let showEmptyState = tasks.isEmpty
    let marker = "**literal**"
    ```

    ```text
    # literal heading
    ```

    更多说明见 [项目文档](https://example.com/docs)。

    **检查完成**，可以回到 Mac 继续。
    """
}
#endif
