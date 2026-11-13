export type CommandParams = Array<[string, string]>;

/** Keep aligned with `AppURLParser.maximumAskLength` and `AppURLParser.maximumURLLength` on macOS & Windows. */
export const MAX_ASK_LENGTH = 500;
export const MAX_COMMAND_URL_LENGTH = 4096;

const WORST_CASE_TOKEN_PLACEHOLDER = "0".repeat(64);
const WORST_CASE_REQUEST_ID_PLACEHOLDER = "0".repeat(32);

/**
 * `menumijia://<route>?…` with the local bridge token and a request id. `encodeURIComponent` writes
 * spaces as %20; the app reads a literal "+" as part of the text, so never use `URLSearchParams`.
 */
export function buildCommandURL(
  route: string,
  params: CommandParams,
  token: string,
  requestId: string,
): string {
  const query = [...params, ["id", requestId], ["token", token]] as CommandParams;
  const encoded = query
    .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
    .join("&");
  const url = `menumijia://${route}?${encoded}`;
  if (url.length > MAX_COMMAND_URL_LENGTH) {
    throw new Error(
      `Command is too long once URL-encoded (${url.length} > ${MAX_COMMAND_URL_LENGTH} ASCII characters). Shorten the text and try again.`,
    );
  }
  return url;
}

export function validateAskText(
  raw: string,
): { ok: true; text: string } | { ok: false; title: string; message?: string } {
  const text = raw.trim();
  if (text.length === 0) {
    return { ok: false, title: "Enter a command first" };
  }
  if (text.length > MAX_ASK_LENGTH) {
    return {
      ok: false,
      title: "Command is too long",
      message: `MenuBarHome accepts up to ${MAX_ASK_LENGTH} characters.`,
    };
  }
  try {
    buildCommandURL("ask", [["text", text]], WORST_CASE_TOKEN_PLACEHOLDER, WORST_CASE_REQUEST_ID_PLACEHOLDER);
  } catch {
    return {
      ok: false,
      title: "Command is too long",
      message: `URL-encoded command exceeds MenuBarHome's ${MAX_COMMAND_URL_LENGTH}-byte link limit. Shorten the text and try again.`,
    };
  }
  return { ok: true, text };
}
