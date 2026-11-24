import { endpointAllowsSendingSecrets, parseAssistantEndpoint } from "../core/assistant.js";

const HAS_SCHEME = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//;

/**
 * One normalizer for every Home Assistant address field (P2-10, #293).
 *
 * The guide, the Settings input, its unsaved-changes comparison and the connect handler all accept
 * what a person actually types: a bare `homeassistant.local:8123` means `http://` (what the native
 * gate assumes for a scheme-less address), and the `/api/websocket` suffix the Home Assistant UI
 * shows is not part of the base URL. Keeping the rule in one function means the plaintext warning
 * can never disagree with the address that is actually saved.
 */
export function normalizeHaEndpoint(raw: string): string {
  let endpoint = raw.trim();
  if (endpoint && !HAS_SCHEME.test(endpoint)) {
    endpoint = `http://${endpoint}`;
  }
  return endpoint.replace(/\/api\/websocket\/?$/i, "").replace(/\/+$/, "");
}

/**
 * True when a typed address would send the long-lived token in cleartext beyond the local network.
 *
 * Delegates the host judgement (IPv4 private ranges, IPv6 ULA/link-local, `.local`/`.lan` names,
 * loopback) to the shared `endpointAllowsSendingSecrets` owner instead of growing a second copy, and
 * stays quiet for input that is not a URL at all.
 */
export function isPlainHttpRemoteEndpoint(raw: string): boolean {
  const endpoint = normalizeHaEndpoint(raw);
  if (!endpoint) return false;
  if (parseAssistantEndpoint(endpoint) === null) return false;
  return !endpointAllowsSendingSecrets(endpoint);
}
