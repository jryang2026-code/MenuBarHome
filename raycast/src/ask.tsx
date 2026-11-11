import { Action, ActionPanel, Form, Icon, showToast, Toast } from "@raycast/api";
import { runCommandWithToast } from "./url";

const MAX_ASK_LENGTH = 500;

export default function Ask() {
  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm
            title="Send Command"
            icon={Icon.ArrowRight}
            onSubmit={async (values: { text?: string }) => {
              const text = (values.text ?? "").trim();
              if (text.length === 0) {
                await showToast({ style: Toast.Style.Failure, title: "Enter a command first" });
                return;
              }
              if (text.length > MAX_ASK_LENGTH) {
                await showToast({
                  style: Toast.Style.Failure,
                  title: "Command is too long",
                  message: `MenuBarHome accepts up to ${MAX_ASK_LENGTH} characters.`,
                });
                return;
              }
              return runCommandWithToast("ask", [["text", text]]);
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
