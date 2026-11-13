import { Action, ActionPanel, Form, Icon, showToast, Toast } from "@raycast/api";
import { runCommandWithToast, validateAskText } from "./url";

export default function Ask() {
  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Send Command"
            icon={Icon.ArrowRight}
            onSubmit={async (values: { text?: string }) => {
              const checked = validateAskText(values.text ?? "");
              if (!checked.ok) {
                await showToast({
                  style: Toast.Style.Failure,
                  title: checked.title,
                  message: checked.message,
                });
                return;
              }
              return runCommandWithToast("ask", [["text", checked.text]]);
            }}
          />
        </ActionPanel>
      }
    >
      <Form.TextArea
        id="text"
        title="Command"
        placeholder="Turn the living room light to 40%"
        info="Runs through MenuBarHome, so the same local parsing, high-risk confirmation and lock-screen rules apply."
        autoFocus
      />
      <Form.Description text="Examples: 把客厅灯调到 40% · 打开书房台灯 · 空调调到 26 度 · 关闭全屋灯光" />
    </Form>
  );
}
