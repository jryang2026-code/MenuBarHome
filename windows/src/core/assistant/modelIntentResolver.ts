import type { HttpTransport } from "../miCloudClient.js";
import type { AssistantSuggestion, HomeScene, IntentOperation, IntentPlan, SmartDevice } from "../models.js";
import { ModelActionPolicy, type ChosenAction } from "./actionPolicy.js";
import type { AssistantContext } from "./context.js";
import { EMPTY_ASSISTANT_CONTEXT } from "./context.js";
import { habitActionable, habitSuggestionTitle } from "./habits.js";
import { IntentReply, IntentValidator } from "./intent.js";
import {
  endpointAllowsSendingSecrets,
  endpointHostMatches,
  INSECURE_ENDPOINT_MESSAGE,
  parseAssistantEndpoint,
  type AssistantConfig,
} from "./provider.js";
import {
  buildIntentCatalog,
  formatTemperatureValue,
  type IntentCatalog,
  buildProactiveChatRequestBody,
  buildProactiveSystemOneRequestBody,
  buildSystemOneRequestBody,
} from "./promptContext.js";
import { cleanPromptField } from "./promptText.js";

export class ModelIntentResolver {
  private readonly config: AssistantConfig;
  private readonly transport: HttpTransport;

  constructor(config: AssistantConfig, transport: HttpTransport) {
    this.config = config;
    this.transport = transport;
  }

  static isSystemOneModel(model: string): boolean {
    const lower = model.trim().toLowerCase();
    if (lower.includes("jev-router")) return false;
    return lower.includes("jev") || lower.includes("clef") || lower.includes("decision");
  }

  static extractFirstJSONObject(text: string): string | null {
    const start = text.indexOf("{");
    if (start < 0) return null;
    let depth = 0;
    let inString = false;
    let escaped = false;
    for (let i = start; i < text.length; i++) {
      const ch = text[i]!;
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch === "\\") {
          escaped = true;
        } else if (ch === '"') {
          inString = false;
        }
        continue;
      }
      if (ch === '"') {
        inString = true;
      } else if (ch === "{") {
        depth += 1;
      } else if (ch === "}") {
        depth -= 1;
        if (depth === 0) {
          return text.slice(start, i + 1);
        }
      }
    }
    return null;
  }

  get usesSystemOne(): boolean {
    return ModelIntentResolver.isSystemOneModel(this.config.model);
  }

  async resolve(
    utterance: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[],
    context: AssistantContext = EMPTY_ASSISTANT_CONTEXT
  ): Promise<IntentPlan> {
    if (this.usesSystemOne) {
      return this.resolveViaSystemOne(utterance, devices, scenes, context);
    }
    return this.resolveViaChatCompletions(utterance, devices, scenes, context);
  }

  /**
   * Proactive zero-input inference, mirroring macOS
   * `ModelIntentResolver.recommendProactiveSuggestions` (#113): evaluates time, indoor
   * climate, active devices and habit memory over both the SystemOne and chat transports.
   */
  async recommendProactiveSuggestions(
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[],
    context: AssistantContext
  ): Promise<AssistantSuggestion[]> {
    const catalog = buildIntentCatalog(devices, scenes);
    const headers = {
      "Content-Type": "application/json",
      Authorization: `Bearer ${this.effectiveAPIKey()}`,
    };
    if (this.usesSystemOne) {
      const url = this.endpointURL("/systemone");
      const model = this.resolvedSystemOneModel(url);
      const resp = await this.transport({
        url,
        method: "POST",
        headers,
        body: JSON.stringify(
          buildProactiveSystemOneRequestBody({ model, devices, context, catalog }).body,
        ),
      });
      if (resp.status !== 200) {
        throw new Error(this.friendlyHttpError(resp.status));
      }
      return proactiveSuggestionsFromSystemOne(resp.body, devices, scenes);
    }
    const url = this.endpointURL("/chat/completions");
    const resp = await this.sendChatCompletion(
      url,
      headers,
      buildProactiveChatRequestBody(this.config.model, context, catalog),
    );
    const root = JSON.parse(resp.body) as Record<string, unknown>;
    const choices = (root["choices"] as Array<Record<string, Record<string, unknown>>>) ?? [];
    let content = String(choices[0]?.["message"]?.["content"] ?? "");
    const closeThinkIdx = content.toLowerCase().lastIndexOf("</think>");
    if (closeThinkIdx >= 0) {
      content = content.slice(closeThinkIdx + "</think>".length);
    }
    return proactiveSuggestionsFromChat(content, catalog, devices, scenes);
  }

  private endpointURL(path: string): string {
    let base = this.config.baseURL.trim().replace(/\/+$/, "");
    for (const suffix of ["/chat/completions", "/systemone"]) {
      if (base.toLowerCase().endsWith(suffix)) {
        base = base.slice(0, -suffix.length).replace(/\/+$/, "");
      }
    }
    if (base && !base.includes("://")) base = `https://${base}`;
    const endpoint = parseAssistantEndpoint(base);
    if (!endpoint) {
      throw new Error(`AI 服务地址无效：${this.config.baseURL}`);
    }
    if (!endpointAllowsSendingSecrets(base)) {
      throw new Error(INSECURE_ENDPOINT_MESSAGE);
    }
    const pathname = new URL(base).pathname.replace(/\/+$/, "");
    if (endpointHostMatches(endpoint, "openrouter.ai")) {
      if (pathname === "") base += "/api/v1";
      else if (pathname === "/api") base += "/v1";
    } else if (pathname === "") {
      base += "/v1";
    }
    return `${base}${path}`;
  }

  private resolvedSystemOneModel(url: string): string {
    const trimmed = this.config.model.trim();
    const lower = trimmed.toLowerCase();
    const endpoint = parseAssistantEndpoint(url);
    if (endpoint && endpointHostMatches(endpoint, "openrouter.ai")) {
      if (lower.includes("jev") && !trimmed.startsWith("~")) {
        return lower.startsWith("typesafe/") ? `~${trimmed}` : `~typesafe/${trimmed}`;
      }
      return trimmed;
    }
    if (lower.startsWith("~typesafe/")) {
      return trimmed.slice("~typesafe/".length);
    }
    if (lower.startsWith("typesafe/")) {
      return trimmed.slice("typesafe/".length);
    }
    return trimmed || "jev-latest";
  }

  private effectiveAPIKey(): string {
    let key = this.config.apiKey.trim();
    if (key.toLowerCase().startsWith("bearer ")) {
      key = key.slice("bearer ".length).trim();
    }
    return key || "local";
  }

  private async resolveViaSystemOne(
    utterance: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[],
    context: AssistantContext
  ): Promise<IntentPlan> {
    const url = this.endpointURL("/systemone");
    const model = this.resolvedSystemOneModel(url);
    const request = buildSystemOneRequestBody({ model, utterance, devices, scenes, context });

    const resp = await this.transport({
      url,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.effectiveAPIKey()}`,
      },
      body: JSON.stringify(request.body),
    });

    if (resp.status !== 200) {
      throw new Error(this.friendlyHttpError(resp.status));
    }

    return ModelIntentResolver.planFromSystemOne(resp.body, request.catalog, devices, scenes);
  }

  static planFromSystemOne(
    bodyText: string,
    catalogOrAliasMap: IntentCatalog | ReadonlyMap<string, readonly string[]>,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[]
  ): IntentPlan {
    const catalog: IntentCatalog =
      "aliasToIds" in catalogOrAliasMap
        ? catalogOrAliasMap
        : {
            ...buildIntentCatalog(devices, scenes),
            aliasToIds: catalogOrAliasMap,
          };
    const parsed = JSON.parse(bodyText) as Record<string, unknown>;
    const answers = (parsed["answers"] ?? {}) as Record<string, Record<string, unknown>>;
    const targetChoice = String(answers["target"]?.["choice"] ?? "none");
    const opChoice = String(answers["op"]?.["choice"] ?? "");
    const tempChoice = String(answers["temp"]?.["choice"] ?? "none");

    const targetIds = targetChoice !== "none" ? (catalog.aliasToIds.get(targetChoice) ?? []) : [];
    const primaryOp = this.decodeSystemOneOp(opChoice);
    const hasTemp = tempChoice !== "none" && Number.isFinite(Number(tempChoice));

    let confidence = ModelActionPolicy.probabilityOf(answers["target"], targetChoice);
    if (primaryOp) confidence = Math.min(confidence, ModelActionPolicy.probabilityOf(answers["op"], opChoice));
    if (hasTemp) confidence = Math.min(confidence, ModelActionPolicy.probabilityOf(answers["temp"], tempChoice));

    const actions: ChosenAction[] = [];
    const runnerUps: Array<{ prob: number; suggestion: AssistantSuggestion }> = [];
    if (targetChoice !== "none" && targetIds.length > 0) {
      for (const id of targetIds) {
        if (primaryOp) actions.push({ intent: { targetId: id, operation: primaryOp }, confidence, primaryChoice: true });
        if (hasTemp) {
          actions.push({
            intent: { targetId: id, operation: { kind: "targetTemperature", celsius: Number(tempChoice) } },
            confidence,
            primaryChoice: true,
          });
        }
      }
    }

    for (const { alias, device } of catalog.aliasDevices) {
      const answer = answers[`dev_${alias}`];
      if (!answer) continue;
      const choice = String(answer["choice"] ?? "none");
      const probs = (answer["probabilities"] ?? {}) as Record<string, unknown>;
      const choiceProb = ModelActionPolicy.probabilityOf(answer, choice);
      const isFallbackPowerOnForEffect =
        opChoice.startsWith("effect_") && choice === "power_on" && !targetIds.includes(device.id);

      if (choice !== "none" && !isFallbackPowerOnForEffect) {
        for (const op of this.systemOneDeviceOperations(choice)) {
          actions.push({
            intent: { targetId: device.id, operation: op },
            confidence: choiceProb,
            primaryChoice: false,
          });
        }
        continue;
      }

      const candidate =
        choice !== "none"
          ? { choice, prob: choiceProb }
          : bestNonNoneProbability(probs);
      if (candidate && (choice !== "none" || candidate.prob >= ModelActionPolicy.SUGGESTION_FLOOR)) {
        const ops = IntentValidator.sanitize(
          this.systemOneDeviceOperations(candidate.choice).map((operation) => ({
            targetId: device.id,
            operation,
          })),
          devices,
          scenes,
        );
        const first = ops[0];
        const firstTitle = first ? habitSuggestionTitle(first, devices, scenes) : null;
        if (first && firstTitle !== null) {
          const second = ops[1];
          const title =
            first.operation.kind === "hvacMode" && second?.operation.kind === "targetTemperature"
              ? `${firstTitle} · ${formatTemperatureValue(second.operation.celsius)}°C`
              : firstTitle;
          const pct =
            candidate.prob > 0 ? Math.max(20, Math.min(99, Math.round(candidate.prob * 100))) : null;
          runnerUps.push({
            prob: candidate.prob,
            suggestion: {
              id: `jev:${device.id}:${candidate.choice}`,
              title,
              confidencePercent: pct,
              intents: ops,
            },
          });
        }
      }
    }

    const decision = ModelActionPolicy.decide(devices, scenes, { actions });
    const taken = new Set(
      [...decision.intents, ...decision.suggestions.flatMap((item) => item.intents)].map((intent) => intent.targetId),
    );
    const seenTargetSets = new Set<string>();
    const extras = runnerUps
      .filter((item) => item.suggestion.intents.every((intent) => !taken.has(intent.targetId)))
      .sort((a, b) => b.prob - a.prob)
      .filter((item) => {
        const key = [...new Set(item.suggestion.intents.map((intent) => intent.targetId))].sort().join("|");
        if (seenTargetSets.has(key)) return false;
        seenTargetSets.add(key);
        return true;
      })
      .slice(0, 3)
      .map((item) => item.suggestion);
    const suggestions = [...decision.suggestions, ...extras];
    const described = IntentReply.describe(decision.intents, devices, scenes);
    return {
      intents: decision.intents,
      reply: suggestions.length > 0
        ? ModelActionPolicy.confirmationReply(decision.intents.length > 0 ? described : null)
        : described,
      source: "model",
      suggestions,
    };
  }

  private static decodeSystemOneOp(choice: string): IntentOperation | null {
    switch (choice) {
      case "power_on": return { kind: "power", isOn: true };
      case "power_off": return { kind: "power", isOn: false };
      case "effect_night": return { kind: "lightEffect", effect: "Night" };
      case "effect_day": return { kind: "lightEffect", effect: "Day" };
      case "bri_20": return { kind: "brightness", percent: 20 };
      case "bri_50": return { kind: "brightness", percent: 50 };
      case "bri_100": return { kind: "brightness", percent: 100 };
      case "bri_down_20": return { kind: "brightnessStep", delta: -20 };
      case "bri_up_20": return { kind: "brightnessStep", delta: 20 };
      case "ct_2700": return { kind: "colorTemperature", kelvin: 2700 };
      case "ct_4000": return { kind: "colorTemperature", kelvin: 4000 };
      case "ct_6500": return { kind: "colorTemperature", kelvin: 6500 };
      case "hvac_cool": return { kind: "hvacMode", mode: "cool" };
      case "hvac_heat": return { kind: "hvacMode", mode: "heat" };
      case "hvac_dry": return { kind: "hvacMode", mode: "dry" };
      case "hvac_fan": return { kind: "hvacMode", mode: "fan_only" };
      case "hvac_auto": return { kind: "hvacMode", mode: "auto" };
      case "temp": return null; // the temperature itself arrives through the `temp` question
      case "temp_up_2": return { kind: "temperatureStep", delta: 2 };
      case "temp_down_2": return { kind: "temperatureStep", delta: -2 };
      case "fan_low": return { kind: "fanSpeed", speed: "low" };
      case "fan_medium": return { kind: "fanSpeed", speed: "medium" };
      case "fan_high": return { kind: "fanSpeed", speed: "high" };
      case "fan_auto": return { kind: "fanSpeed", speed: "auto" };
      case "osc_on": return { kind: "oscillation", enabled: true };
      case "osc_off": return { kind: "oscillation", enabled: false };
      case "scene": return { kind: "activateScene" };
      default: return null;
    }
  }

  /** Compound SystemOne choices map to a mode plus a temperature (#38/#113). */
  static systemOneDeviceOperations(choice: string): IntentOperation[] {
    switch (choice) {
      case "cool_24": return [{ kind: "hvacMode", mode: "cool" }, { kind: "targetTemperature", celsius: 24 }];
      case "cool_25": return [{ kind: "hvacMode", mode: "cool" }, { kind: "targetTemperature", celsius: 25 }];
      case "cool_26": return [{ kind: "hvacMode", mode: "cool" }, { kind: "targetTemperature", celsius: 26 }];
      case "heat_22": return [{ kind: "hvacMode", mode: "heat" }, { kind: "targetTemperature", celsius: 22 }];
      case "heat_24": return [{ kind: "hvacMode", mode: "heat" }, { kind: "targetTemperature", celsius: 24 }];
      default: {
        const op = this.decodeSystemOneOp(choice);
        return op ? [op] : [];
      }
    }
  }

  static systemPrompt(catalog: IntentCatalog, context: AssistantContext = EMPTY_ASSISTANT_CONTEXT): string {
    const contextParts = [
      context.timeSummary,
      context.environmentSummary,
      context.activeDevicesSummary,
      context.habitSummary,
    ]
      .map((field) => cleanPromptField(field))
      .filter((field) => field.length > 0);
    const contextBlock = contextParts.length > 0 ? `\n当前环境与习惯：${contextParts.join("；")}\n` : "";
    return (
      `你是智能家居指令解析器。把用户的中文指令转换为 JSON，只输出 JSON，不要解释。${contextBlock}\n` +
      `${catalog.text}\n` +
      `schema: {"actions":[{"device":"id","op":"power|brightness|brightness_step|color_temp|effect|hvac_mode|temperature|temperature_step|fan_speed|oscillation|scene","value":...}],"reply":"一句话中文回执"}\n` +
      `规则：power 的 value 为 true/false；brightness 为 1-100（调暗用 20，调亮用 100）；color_temp 为开尔文；` +
      `effect 取 Day（日光模式）或 Night（月光/夜灯模式），且必须是该灯具的可用模式；` +
      `hvac_mode 取 cool/heat/dry/fan_only/auto/off 且必须是该设备的可用模式；temperature 为摄氏度数字；` +
      `brightness_step / temperature_step 是相对调节（"再暗一点"=-20，"调高两度"=2），优先用于"再…一点"类说法；` +
      `fan_speed 取 high/medium/low/auto 或该设备"可选风速"里的原名；oscillation 为 true/false（风扇摇头）；` +
      `scene 的 device 填场景 id，value 填 null。只能使用上面列出的 id。` +
      `无法执行时 actions 为空数组，并在 reply 中简短说明原因。`
    );
  }

  private async resolveViaChatCompletions(
    utterance: string,
    devices: readonly SmartDevice[],
    scenes: readonly HomeScene[],
    context: AssistantContext = EMPTY_ASSISTANT_CONTEXT
  ): Promise<IntentPlan> {
    const url = this.endpointURL("/chat/completions");
    const catalog = buildIntentCatalog(devices, scenes);
    const prompt = ModelIntentResolver.systemPrompt(catalog, context);

    const resp = await this.sendChatCompletion(
      url,
      {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.effectiveAPIKey()}`,
      },
      {
        model: this.config.model.trim(),
        messages: [
          { role: "system", content: prompt },
          { role: "user", content: utterance },
        ],
        temperature: 0,
      },
    );

    const root = JSON.parse(resp.body) as Record<string, unknown>;
    const choices = (root["choices"] as Array<Record<string, Record<string, unknown>>>) ?? [];
    let content = String(choices[0]?.["message"]?.["content"] ?? "");
    const closeThinkIdx = content.toLowerCase().lastIndexOf("</think>");
    if (closeThinkIdx >= 0) {
      content = content.slice(closeThinkIdx + "</think>".length);
    }
    const jsonSlice = ModelIntentResolver.extractFirstJSONObject(content);
    if (!jsonSlice) throw new Error("AI 返回格式无法解析");
    const payload = JSON.parse(jsonSlice) as Record<string, unknown>;
    const actions = (payload["actions"] as Array<Record<string, unknown>>) ?? [];

    const chosen: ChosenAction[] = [];
    for (const act of actions) {
      const alias = String(act["device"] ?? "").trim();
      const opName = String(act["op"] ?? "").trim();
      const val = act["value"];
      const op = ModelIntentResolver.decodeChatOp(opName, val);
      const targetIds = catalog.aliasToIds.get(alias) ?? [];
      if (op) {
        for (const targetId of targetIds) {
          chosen.push({ intent: { targetId, operation: op }, confidence: null, primaryChoice: false });
        }
      }
    }
    const rawSuggestions = Array.isArray(payload["suggestions"])
      ? (payload["suggestions"] as Array<Record<string, unknown>>)
      : [];
    const decision = ModelActionPolicy.decide(devices, scenes, { actions: chosen });
    const confirmChips = decision.suggestions;
    const primaryTargetIds = new Set(
      [...decision.intents, ...confirmChips.flatMap((chip) => chip.intents)].map((intent) => intent.targetId),
    );
    const parsedSuggestions = parseChatSuggestionItems(rawSuggestions, catalog, devices, scenes).filter(
      (suggestion) => !suggestion.intents.some((intent) => primaryTargetIds.has(intent.targetId)),
    );
    const described = IntentReply.describe(decision.intents, devices, scenes);
    const modelReply = String(payload["reply"] ?? "").trim();
    const reply = confirmChips.length > 0
      ? ModelActionPolicy.confirmationReply(decision.intents.length > 0 ? described : null)
      : modelReply || described;
    return {
      intents: decision.intents,
      reply,
      source: "model",
      suggestions: [...confirmChips, ...parsedSuggestions],
    };
  }

  static decodeChatOp(name: string, val: unknown): IntentOperation | null {
    const numVal = typeof val === "number" ? val : typeof val === "string" ? Number(val.replace(/[%°CcKk\s]/g, "")) : NaN;
    const boolVal =
      typeof val === "boolean"
        ? val
        : typeof val === "number"
          ? val !== 0
          : typeof val === "string"
            ? ["true", "on", "1", "开"].includes(val.trim().toLowerCase())
            : false;

    switch (name.toLowerCase()) {
      case "power": return { kind: "power", isOn: boolVal };
      case "brightness": return Number.isFinite(numVal) ? { kind: "brightness", percent: Math.round(numVal) } : null;
      case "brightness_step": return Number.isFinite(numVal) ? { kind: "brightnessStep", delta: Math.round(numVal) } : null;
      case "color_temp":
      case "color_temperature":
        return Number.isFinite(numVal) ? { kind: "colorTemperature", kelvin: Math.round(numVal) } : null;
      case "effect":
      case "light_effect":
        return typeof val === "string" ? { kind: "lightEffect", effect: val } : null;
      case "hvac_mode":
      case "mode":
        return typeof val === "string" ? { kind: "hvacMode", mode: val } : null;
      case "temperature":
      case "target_temperature":
        return Number.isFinite(numVal) ? { kind: "targetTemperature", celsius: numVal } : null;
      case "temperature_step":
        return Number.isFinite(numVal) ? { kind: "temperatureStep", delta: numVal } : null;
      case "fan_speed":
      case "fan_mode":
      case "preset":
        return typeof val === "string" ? { kind: "fanSpeed", speed: val } : null;
      case "oscillation":
      case "swing":
        return { kind: "oscillation", enabled: boolVal };
      case "scene":
        return { kind: "activateScene" };
      default: return null;
    }
  }

  /**
   * Sends an OpenAI-compatible chat request. Some models only accept their own fixed
   * sampling temperature (e.g. Kimi Code rejects `temperature: 0`, #260), so a 400 whose
   * body names `temperature` is retried once without that field. Mirrors macOS
   * `sendChatCompletion`.
   */
  private async sendChatCompletion(
    url: string,
    headers: Record<string, string>,
    body: Record<string, unknown>,
  ) {
    const resp = await this.transport({ url, method: "POST", headers, body: JSON.stringify(body) });
    if (resp.status === 200) return resp;
    if (resp.status === 400 && "temperature" in body && /temperature/i.test(resp.body.slice(0, 4096))) {
      const { temperature: _dropped, ...withoutTemperature } = body;
      const retry = await this.transport({ url, method: "POST", headers, body: JSON.stringify(withoutTemperature) });
      if (retry.status === 200) return retry;
      throw new Error(this.friendlyHttpError(retry.status));
    }
    throw new Error(this.friendlyHttpError(resp.status));
  }

  private friendlyHttpError(status: number): string {
    if (status === 401 || status === 403) return "API Key 无效或未填写，请在设置中检查";
    if (status === 429) return "AI 调用过于频繁（触发限流），请稍后再试";
    if (status >= 500) return `AI 服务端暂时不可用 (HTTP ${status})`;
    return `AI 请求失败 (HTTP ${status})`;
  }
}

function numberFromValue(value: unknown): number | null {
  const n = typeof value === "number" ? value : typeof value === "string" ? Number(value) : NaN;
  return Number.isFinite(n) ? n : null;
}

/** Best scored non-none probability in a decision head's `probabilities` map. */
function bestNonNoneProbability(probabilities: Record<string, unknown>): { choice: string; prob: number } | null {
  let best: { choice: string; prob: number } | null = null;
  for (const [key, raw] of Object.entries(probabilities)) {
    if (key === "none") continue;
    const prob = numberFromValue(raw);
    if (prob !== null && prob > (best?.prob ?? 0)) best = { choice: key, prob };
  }
  return best;
}

/** Parses SystemOne proactive answers into ranked suggestions; mirrors macOS `proactiveSuggestionsFromSystemOne` (#113). */
export function proactiveSuggestionsFromSystemOne(
  bodyText: string,
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
): AssistantSuggestion[] {
  const parsed = JSON.parse(bodyText) as Record<string, unknown>;
  const answers = (parsed["answers"] ?? {}) as Record<string, Record<string, unknown>>;
  const catalog = buildIntentCatalog(devices, scenes);
  const scored: Array<{ prob: number; suggestion: AssistantSuggestion }> = [];

  for (const { alias, device } of catalog.aliasDevices) {
    const answer = answers[`dev_${alias}`];
    if (!answer) continue;
    const probabilities = (answer["probabilities"] ?? {}) as Record<string, unknown>;
    const topChoice = String(answer["choice"] ?? "none");

    let chosenKey: string;
    let chosenProb: number;
    if (topChoice !== "none") {
      chosenKey = topChoice;
      chosenProb = numberFromValue(probabilities[topChoice]) ?? numberFromValue(answer["confidence"]) ?? 0.65;
    } else {
      const runnerUp = bestNonNoneProbability(probabilities);
      if (!runnerUp || runnerUp.prob < 0.18) continue;
      chosenKey = runnerUp.choice;
      chosenProb = runnerUp.prob;
    }

    const ops = IntentValidator.sanitize(
      ModelIntentResolver.systemOneDeviceOperations(chosenKey).map((operation) => ({ targetId: device.id, operation })),
      devices,
      scenes,
    );
    if (!ops.some((intent) => habitActionable(intent, devices, scenes))) continue;
    const primary = ops[0];
    if (!primary) continue;
    const firstTitle = habitSuggestionTitle(primary, devices, scenes);
    if (firstTitle === null) continue;
    const second = ops[1];
    const title =
      primary.operation.kind === "hvacMode" && second?.operation.kind === "targetTemperature"
        ? `${firstTitle} · ${formatTemperatureValue(second.operation.celsius)}°C`
        : firstTitle;
    scored.push({
      prob: chosenProb,
      suggestion: {
        id: `proactive:${device.id}:${chosenKey}`,
        title,
        confidencePercent: Math.max(18, Math.min(99, Math.round(chosenProb * 100))),
        intents: ops,
      },
    });
  }

  return scored
    .sort((a, b) => b.prob - a.prob)
    .slice(0, 3)
    .map((item) => item.suggestion);
}

function parseChatSuggestionItems(
  items: readonly Record<string, unknown>[],
  catalog: IntentCatalog,
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
): AssistantSuggestion[] {
  const scored: Array<{ pct: number; suggestion: AssistantSuggestion }> = [];
  items.forEach((item, idx) => {
    const alias = String(item["device"] ?? "").trim();
    const opName = String(item["op"] ?? "").trim();
    const op = ModelIntentResolver.decodeChatOp(opName, item["value"]);
    if (!op || !alias) return;
    const targetIds = catalog.aliasToIds.get(alias) ?? [alias];
    const sanitized = IntentValidator.sanitize(
      targetIds.map((targetId) => ({ targetId, operation: op })),
      devices,
      scenes,
    );
    const primary = sanitized[0];
    if (!primary) return;
    const title = habitSuggestionTitle(primary, devices, scenes);
    if (title === null) return;
    const rawConf = numberFromValue(item["confidence"]) ?? 80;
    const normalizedConf = rawConf <= 1.0 ? Math.round(rawConf * 100) : Math.round(rawConf);
    const pct = Math.max(18, Math.min(99, normalizedConf));
    scored.push({
      pct,
      suggestion: {
        id: `chat:${primary.targetId}:${idx}`,
        title,
        confidencePercent: pct,
        intents: [primary],
      },
    });
  });
  return scored
    .sort((a, b) => b.pct - a.pct)
    .slice(0, 3)
    .map((item) => item.suggestion);
}

/** Parses proactive chat output into ranked suggestions; mirrors macOS `proactiveSuggestionsFromChat` (#113). */
export function proactiveSuggestionsFromChat(
  content: string,
  catalog: IntentCatalog,
  devices: readonly SmartDevice[],
  scenes: readonly HomeScene[],
): AssistantSuggestion[] {
  const jsonSlice = ModelIntentResolver.extractFirstJSONObject(content);
  if (!jsonSlice) throw new Error("AI 返回格式无法解析");
  const payload = JSON.parse(jsonSlice) as Record<string, unknown>;
  const items = (payload["suggestions"] as Array<Record<string, unknown>>) ?? (payload["actions"] as Array<Record<string, unknown>>) ?? [];
  return parseChatSuggestionItems(items, catalog, devices, scenes);
}
