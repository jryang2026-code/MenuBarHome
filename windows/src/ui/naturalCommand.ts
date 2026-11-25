import { cancelScheduledCommands, enqueueScheduledCommand, scheduledCommandsGeneration } from "./scheduledCommands.js";
import type { MenuMijiaWindowsApp } from "./app.js";
import { t } from "../core/i18n.js";
import { answerStateQuery, parseStateQuery } from "../core/assistant/stateQuery.js";
import { parseQuickActionCommand } from "../core/quickActions.js";
import { missingScheduledCommandTargets, isScheduledCommandsEnabled } from "../core/scheduledCommands.js";
import {
  DelayPhrase,
  INSECURE_ENDPOINT_MESSAGE,
  IntentReply,
  IntentValidator,
  LocalIntentParser,
  ManualControlPolicy,
  ModelActionPolicy,
  ModelIntentResolver,
  UndoPhrase,
  UserHabitMemory,
  assistantEndpointIdentity,
  buildAssistantContext,
  endpointAllowsSendingSecrets,
  isAiAssistantEnabled,
  isLocalAssistantEndpoint,
  suggestionBaseId,
  withSuggestionDelay,
  type ConfirmationPolicy,
  type LocalIntentParseOptions,
  type SuggestionDelaySpec,
} from "../core/assistant.js";
import type { AssistantSuggestion, DeviceIntent, IntentPlan, ScheduledCommand } from "../core/models.js";
import type { HttpTransport } from "../core/miCloudClient.js";
import { withAliases } from "./panelPrefs.js";
import { executeBuiltInQuickAction } from "./speechGuard.js";
import { buildHostCapabilityContext, isDualSourceEnabled } from "./cloudRefresh.js";
import { buildDiffPreview, requiresDiffPreview } from "../core/assistantDiffPreview.js";
import {
  evaluateDisabledUtteranceGate,
  evaluateIntentsWriteGate,
  evaluateIntentsWriteGateVerdict,
} from "../core/miAccountControl.js";

function localParseOptions(host: MenuMijiaWindowsApp): LocalIntentParseOptions {
  const cut = host.listCut;
  return {
    panelRoom: cut.kind === "room"
      ? { id: cut.roomId, name: cut.roomName }
      : null,
    usageOrder: new UserHabitMemory(
      host.settings.habitEntries,
      host.habitSequences(),
      host.lastHabitAction(),
    ).usageOrder(),
  };
}

export async function handleNaturalCommand(
  host: MenuMijiaWindowsApp,
  rawInput: string,
  fromScheduled = false,
  preferDiffPreview = false,
): Promise<void> {
    let trimmed = rawInput.trim();
    if (!trimmed) return;
    const sourceRevision = host.sourceRevision;
    // A disable or provider change mid-flight must discard this run's late model result
    // before it can reach the write gate (P5a-W acceptance #3).
    const assistantEpoch = host.assistantEpoch;
    // A new command replaces any question still waiting for cloud consent, and old suggestions.
    host.pendingCloudConsent = null;
    host.pendingDiffPreview = null;
    host.pendingSuggestions = [];

    const delaySpec = !fromScheduled ? DelayPhrase.extract(trimmed) : null;
    const query = parseStateQuery(delaySpec?.remainder ?? trimmed);
    if (query) {
      if (host.isResolvingIntent) host.advanceAssistantEpoch();
      if (delaySpec) {
        host.replyBanner = { text: t("定时查询仅支持查看当前状态"), source: t("本地直达"), isError: true };
        host.render();
        return;
      }
      const plan = answerStateQuery(query, withAliases(host.layout, host.devices));
      host.replyBanner = plan
        ? { text: plan.reply, source: t("本地直达") }
        : { text: t("当前快照没有可回答的状态"), source: t("本地直达"), isError: true };
      host.render();
      return;
    }

    const quickActionId = parseQuickActionCommand(trimmed);
    if (quickActionId) {
      await executeBuiltInQuickAction(host, quickActionId);
      return;
    }

    if (UndoPhrase.isUndo(trimmed)) {
      await host.performUndo();
      return;
    }

    if (DelayPhrase.isCancel(trimmed)) {
      const count = cancelScheduledCommands(host);
      if (count < 0) return;
      host.replyBanner = {
        text: count > 0 ? t("已取消 {count} 项定时指令", { count: count }) : t("当前没有待执行的定时指令"),
        source: t("本地直达"),
      };
      host.render();
      return;
    }

    if (!fromScheduled) {
      if (delaySpec) {
        // A learned phrase wins over the generic parser, exactly as it does without a delay.
        const learned = host.settings.learnedShortcuts.find(
          (shortcut) => shortcut.phrase.replace(/\s+/g, "") === delaySpec.remainder.replace(/\s+/g, ""),
        );
        if (learned) {
          queueScheduledCommand(host, delaySpec, learned.intents);
          return;
        }
        const aliasedDevices = withAliases(host.layout, host.devices);
        const resolved = LocalIntentParser.parse(
          delaySpec.remainder,
          aliasedDevices,
          host.scenes,
          localParseOptions(host),
        );
        if (!resolved || resolved.intents.length === 0) {
          if (
            resolved &&
            resolved.suggestions.length > 0 &&
            !resolved.suggestions.every((s) => suggestionBaseId(s.id).startsWith("bare:"))
          ) {
            const spec: SuggestionDelaySpec = {
              seconds: delaySpec.seconds,
              label: `${DelayPhrase.formatDelay(delaySpec.seconds)}后`,
              command: delaySpec.remainder,
            };
            host.pendingSuggestions = resolved.suggestions.map((chip) => withSuggestionDelay(chip, spec));
            host.replyBanner = {
              text: resolved.reply || ModelActionPolicy.confirmationReply(null),
              source: t("需要确认"),
            };
            host.render();
            return;
          }
          if (host.settings.connectionMode !== "demo" || isDualSourceEnabled(host)) {
            const disabledMsg = evaluateDisabledUtteranceGate({
              utterance: delaySpec.remainder,
              context: buildHostCapabilityContext(host),
              aliases: host.layout.aliases,
              languagePreference: host.settings.interfaceLanguage,
            });
            if (disabledMsg !== null) {
              host.pendingSuggestions = [];
              host.replyBanner = { text: disabledMsg, source: t("控制失败"), isError: true };
              host.render();
              return;
            }
          }
          if (resolved) {
            host.pendingSuggestions = [];
            host.replyBanner = {
              text: resolved.reply || t("无法找到指令对应的设备"),
              source: t("本地直达"),
            };
            host.render();
            return;
          }
        }
        if (resolved && resolved.intents.length > 0 && (host.settings.connectionMode !== "demo" || isDualSourceEnabled(host))) {
          const gateMsg = evaluateIntentsWriteGate({
            intents: resolved.intents,
            context: buildHostCapabilityContext(host),
            languagePreference: host.settings.interfaceLanguage,
          });
          if (gateMsg !== null) {
            host.pendingSuggestions = [];
            host.replyBanner = { text: gateMsg, source: t("控制失败"), isError: true };
            host.render();
            return;
          }
        }
        if (
          resolved &&
          resolved.intents.some((intent) => ManualControlPolicy.requiresConfirmation(intent, aliasedDevices))
        ) {
          const spec: SuggestionDelaySpec = {
            seconds: delaySpec.seconds,
            label: `${DelayPhrase.formatDelay(delaySpec.seconds)}后`,
            command: delaySpec.remainder,
          };
          host.pendingSuggestions = ModelActionPolicy.chips(
            resolved.intents,
            null,
            "confirm:local",
            aliasedDevices,
            host.scenes,
            true,
          ).map((chip) => withSuggestionDelay(chip, spec));
          host.replyBanner = {
            text: t("高风险设备需要先确认，未设定定时"),
            source: t("需要确认"),
          };
          host.render();
          return;
        }
        if (resolved) {
          queueScheduledCommand(host, delaySpec, resolved.intents);
          return;
        }
        trimmed = delaySpec.remainder;
      }
    }

    const learnedMatch = host.settings.learnedShortcuts.find(
      (s) => s.phrase.replace(/\s+/g, "") === trimmed.replace(/\s+/g, ""),
    );
    if (learnedMatch) {
      // A timer firing a learned phrase is not a user action, so it never trains habits (#34/#113).
      await host.executeIntents(learnedMatch.intents, learnedMatch.reply, t("习惯记忆 0ms"), { recordHabits: !fromScheduled });
      return;
    }

    host.isResolvingIntent = true;
    host.render();

    try {
      const aliasedDevices = withAliases(host.layout, host.devices);
      const localPlan = LocalIntentParser.parse(trimmed, aliasedDevices, host.scenes, localParseOptions(host));
      let plan: IntentPlan | null = localPlan;
      let sourceLabel = t("本地直达");

      if (
        (!plan || (plan.intents.length === 0 && plan.suggestions.length === 0)) &&
        (host.settings.connectionMode !== "demo" || isDualSourceEnabled(host))
      ) {
        const disabledMsg = evaluateDisabledUtteranceGate({
          utterance: trimmed,
          context: buildHostCapabilityContext(host),
          aliases: host.layout.aliases,
          languagePreference: host.settings.interfaceLanguage,
        });
        if (disabledMsg !== null) {
          host.pendingSuggestions = [];
          host.replyBanner = { text: disabledMsg, source: t("控制失败"), isError: true };
          host.isResolvingIntent = false;
          host.render();
          return;
        }
      }

      if (!plan) {
        if (!isAiAssistantEnabled(host.settings)) {
          // AI is off: zero requests, zero retries, no cloud consent prompt. Local parsing,
          // learned shortcuts and saved timers were already handled above.
          host.pendingSuggestions = [];
          host.replyBanner = {
            text: t("AI 一句话控制已关闭，指令只在本机解析；可在设置中重新开启。"),
            source: t("AI 一句话控制"),
          };
          host.isResolvingIntent = false;
          host.render();
          return;
        }
        const baseURL = host.settings.assistantBaseURL.trim() || "https://openrouter.ai/api/v1";
        const apiKey = host.apiKeyFor(baseURL);
        const isLoopback = isLocalAssistantEndpoint(baseURL);
        if (!endpointAllowsSendingSecrets(baseURL)) {
          host.replyBanner = { text: INSECURE_ENDPOINT_MESSAGE, source: t("地址不安全"), isError: true };
          host.isResolvingIntent = false;
          host.render();
          return;
        }
        if (!apiKey && !isLoopback) {
          host.replyBanner = {
            text: t("未命中本地规则。请在设置中填写 AI 服务的 API Key（支持 OpenRouter Jev、原生 Jev、DeepSeek 等）。"),
            source: t("需要 API Key"),
            isError: true,
          };
          host.isResolvingIntent = false;
          host.render();
          return;
        }
        const endpoint = assistantEndpointIdentity(baseURL);
        if (!isLoopback && endpoint && !host.settings.cloudConsentEndpoints.includes(endpoint)) {
          host.pendingCloudConsent = { utterance: rawInput.trim(), endpoint };
          host.replyBanner = {
            text: t("这句话本机没听懂，要交给云端 AI（{endpoint}）处理吗？会发送：这句话、设备名称/房间/状态。只问这一次，可在设置里撤销。", { endpoint: endpoint }),
            source: t("需要确认"),
          };
          host.isResolvingIntent = false;
          host.render();
          return;
        }
        const settingsRecord = host.settings as unknown as Record<string, unknown>;
        const confirmationPolicy: Partial<ConfirmationPolicy> = {
          ...(typeof settingsRecord.askWhenUnsure === "boolean"
            ? { askWhenUnsure: settingsRecord.askWhenUnsure }
            : {}),
          ...(typeof settingsRecord.confirmationThreshold === "number"
            ? { threshold: settingsRecord.confirmationThreshold }
            : {}),
        };
        // Gate every transport attempt (initial call and in-resolver retries alike): once
        // the run is superseded or AI is off, no further request may leave (P5a-W #1/#3).
        const gatedTransport: HttpTransport = (request) => {
          if (assistantEpoch !== host.assistantEpoch || !isAiAssistantEnabled(host.settings)) {
            return Promise.reject(new Error("assistant request superseded"));
          }
          return host.transport(request);
        };
        const resolver = new ModelIntentResolver(
          {
            baseURL,
            model: host.settings.assistantModel,
            apiKey,
          },
          gatedTransport,
          confirmationPolicy,
        );
        // Same ambient context macOS sends with Jev requests (#38); the getter falls
        // back to sensor devices when no refreshed EnvironmentReading list exists.
        const readings = host.computedEnvironmentReadings;
        const context = buildAssistantContext({
          now: new Date(),
          readings,
          devices: aliasedDevices,
          scenes: host.scenes,
          sharing: host.settings.habitShareEnabled ? "on" : "off",
          memory: new UserHabitMemory(host.settings.habitEntries, host.habitSequences(), host.lastHabitAction()),
          phrases: host.settings.learnedShortcuts.map((shortcut) => ({
            phrase: shortcut.phrase,
            intents: shortcut.intents,
          })),
          mention: { kind: "utterance", text: trimmed },
        });
        plan = await resolver.resolve(trimmed, aliasedDevices, host.scenes, context);
        if (sourceRevision !== host.sourceRevision || assistantEpoch !== host.assistantEpoch) return;
        sourceLabel = resolver.usesSystemOne ? "Jev SystemOne" : host.settings.assistantModel;
      }

      if (plan.intents.length > 0 && (host.settings.connectionMode !== "demo" || isDualSourceEnabled(host))) {
        const gateMsg = evaluateIntentsWriteGate({
          intents: plan.intents,
          context: buildHostCapabilityContext(host),
          languagePreference: host.settings.interfaceLanguage,
        });
        if (gateMsg !== null) {
          host.pendingSuggestions = [];
          host.replyBanner = { text: gateMsg, source: t("控制失败"), isError: true };
          host.isResolvingIntent = false;
          host.render();
          return;
        }
      }

      const sanitized = IntentValidator.sanitize(plan.intents, aliasedDevices, host.scenes);
      host.pendingSuggestions = [...plan.suggestions];
      // A local plan has no confirmation step of its own, so a high-risk auto-resolved target waits
      // for a tap before it runs (#274 review). Low-risk devices execute immediately.
      const hazardous = sanitized.filter((intent) =>
        ManualControlPolicy.requiresConfirmation(intent, aliasedDevices),
      );
      if (delaySpec) {
        const spec: SuggestionDelaySpec = {
          seconds: delaySpec.seconds,
          label: `${DelayPhrase.formatDelay(delaySpec.seconds)}后`,
          command: delaySpec.remainder,
        };
        if (hazardous.length > 0) {
          host.pendingSuggestions = ModelActionPolicy.chips(
            sanitized,
            null,
            "confirm:local",
            aliasedDevices,
            host.scenes,
            true,
          ).map((chip) => withSuggestionDelay(chip, spec));
          host.replyBanner = { text: t("高风险设备需要先确认，未设定定时"), source: t("需要确认") };
        } else if (sanitized.length === 0 && plan.suggestions.length > 0) {
          host.pendingSuggestions = plan.suggestions.map((chip) => withSuggestionDelay(chip, spec));
          host.replyBanner = {
            text: plan.reply || ModelActionPolicy.confirmationReply(null),
            source: t("需要确认"),
          };
        } else if (sanitized.length === 0) {
          host.pendingSuggestions = [];
          host.replyBanner = { text: t("定时指令需要明确的设备和操作，未设定定时"), source: t("需要确认") };
        } else {
          host.pendingSuggestions =
            plan.suggestions.length > 0
              ? plan.suggestions.map((chip) => withSuggestionDelay(chip, spec))
              : [];
          queueScheduledCommand(host, delaySpec, sanitized);
          return;
        }
        host.render();
        return;
      }
      if (preferDiffPreview && sanitized.length > 0 && requiresDiffPreview(sanitized, aliasedDevices)) {
        const replyText = plan.reply || IntentReply.describe(sanitized, aliasedDevices, host.scenes);
        host.pendingDiffPreview = buildDiffPreview({
          intents: sanitized,
          devices: aliasedDevices,
          scenes: host.scenes,
          replyText,
          sourceLabel,
          utterance: trimmed,
          recordHabits: plan.source === "local" && !fromScheduled,
          learnAfterRun: host.settings.habitLearningEnabled && plan.source === "model",
          sourceRevision,
        });
        if (hazardous.length > 0) {
          host.pendingSuggestions = ModelActionPolicy.chips(sanitized, null, "confirm:local", aliasedDevices, host.scenes, true);
          const hint = ManualControlPolicy.wallSwitchLightHintForIntents(hazardous, aliasedDevices);
          host.replyBanner = {
            text: t("「{action}」属于高风险设备，再点一次确认执行", {
              action: IntentReply.describe(hazardous, aliasedDevices, host.scenes).replace(/^已/, ""),
            }),
            source: t("需要确认"),
            ...(hint ? { hint } : {}),
          };
        }
        host.isResolvingIntent = false;
        host.render();
        return;
      }
      if (hazardous.length > 0) {
        host.pendingSuggestions = ModelActionPolicy.chips(sanitized, null, "confirm:local", aliasedDevices, host.scenes, true);
        const hint = ManualControlPolicy.wallSwitchLightHintForIntents(hazardous, aliasedDevices);
        host.replyBanner = {
          text: t("「{action}」属于高风险设备，再点一次确认执行", {
            action: IntentReply.describe(hazardous, aliasedDevices, host.scenes).replace(/^已/, ""),
          }),
          source: t("需要确认"),
          ...(hint ? { hint } : {}),
        };
        host.render();
        return;
      }
      if (sanitized.length === 0 && plan.suggestions.length > 0) {
        host.replyBanner = { text: plan.reply || ModelActionPolicy.confirmationReply(null), source: t("需要确认") };
        return;
      }
      if (sanitized.length === 0) {
        host.replyBanner =
          plan.intents.length > 0
            ? { text: t("无法找到指令对应的设备"), source: t("控制失败"), isError: true }
            : { text: plan.reply || t("无法找到指令对应的设备"), source: sourceLabel, isError: !plan.reply };
        return;
      }
      const replyText =
        plan.reply || IntentReply.describe(sanitized, aliasedDevices, host.scenes);
      const succeeded = await host.executeIntents(sanitized, replyText, sourceLabel, {
        recordHabits: plan.source === "local" && !fromScheduled,
      });
      if (sourceRevision !== host.sourceRevision || assistantEpoch !== host.assistantEpoch) return;

      if (
        succeeded &&
        host.settings.habitLearningEnabled &&
        plan.source === "model" &&
        sanitized.length > 0
      ) {
        learnShortcut(host, trimmed, replyText, sanitized);
      }
    } catch (err) {
      if (sourceRevision !== host.sourceRevision || assistantEpoch !== host.assistantEpoch) return;
      const msg = err instanceof Error ? err.message : String(err);
      host.replyBanner = {
        text: msg,
        source: t("出错提示"),
        isError: true,
      };
    } finally {
      if (sourceRevision === host.sourceRevision && assistantEpoch === host.assistantEpoch) {
        host.isResolvingIntent = false;
        host.render();
      }
    }
  }

function queueScheduledCommand(
  host: MenuMijiaWindowsApp,
  delaySpec: NonNullable<ReturnType<typeof DelayPhrase.extract>>,
  intents: readonly DeviceIntent[],
  options: { readonly allowConfirmedHazardous?: boolean } = {},
): void {
  if (host.settings.connectionMode !== "demo" || isDualSourceEnabled(host)) {
    const gateMsg = evaluateIntentsWriteGate({
      intents,
      context: buildHostCapabilityContext(host),
      languagePreference: host.settings.interfaceLanguage,
    });
    if (gateMsg !== null) {
      host.replyBanner = { text: gateMsg, source: t("控制失败"), isError: true };
      host.render();
      return;
    }
  }
  const devices = withAliases(host.layout, host.devices);
  const sanitized = IntentValidator.sanitize(intents, devices, host.scenes);
  if (sanitized.length === 0) {
    host.replyBanner = { text: t("无法找到指令对应的设备"), source: t("定时任务"), isError: true };
    host.render();
    return;
  }
  if (
    !options.allowConfirmedHazardous &&
    sanitized.some((intent) => ManualControlPolicy.requiresConfirmation(intent, devices))
  ) {
    host.replyBanner = { text: t("高风险设备需要先确认，未设定定时"), source: t("需要确认") };
    host.render();
    return;
  }
  const scheduled: ScheduledCommand = {
    id: `${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
    command: delaySpec.remainder,
    delaySeconds: delaySpec.seconds,
    fireTimestampMs: Date.now() + delaySpec.seconds * 1000,
    reply: t("{delay}后：{command}", { delay: DelayPhrase.formatDelay(delaySpec.seconds), command: delaySpec.remainder }),
    intents: sanitized,
  };
  if (!enqueueScheduledCommand(host, scheduled)) return;
  host.replyBanner = {
    text: t("已设定 {delay}后执行「{command}」", { delay: DelayPhrase.formatDelay(delaySpec.seconds), command: delaySpec.remainder }),
    source: t("定时任务"),
  };
  host.render();
}

export function confirmDelayedSuggestion(
  host: MenuMijiaWindowsApp,
  suggestion: AssistantSuggestion,
  delaySpec: SuggestionDelaySpec,
): void {
  const aliasedDevices = withAliases(host.layout, host.devices);
  const fallbackCommand = IntentReply.describe(suggestion.intents, aliasedDevices, host.scenes).replace(/^已/, "");
  const remainder = delaySpec.command?.trim() || fallbackCommand;
  queueScheduledCommand(
    host,
    { seconds: delaySpec.seconds, remainder },
    suggestion.intents,
    { allowConfirmedHazardous: true },
  );
}

export async function runScheduledCommand(
  host: MenuMijiaWindowsApp,
  item: ScheduledCommand,
  userInitiated = false,
  allowWhileLocked = false,
): Promise<void> {
  if (item.intents && item.intents.length > 0) {
    const gateFailure =
      host.settings.connectionMode !== "demo" || isDualSourceEnabled(host)
        ? evaluateIntentsWriteGateVerdict({
            intents: item.intents,
            context: buildHostCapabilityContext(host),
            languagePreference: host.settings.interfaceLanguage,
          })
        : null;
    const gateMsg = gateFailure?.message ?? null;
    const missingTargets = missingScheduledCommandTargets(item, host.devices, host.scenes);
    if (gateMsg !== null && missingTargets.length === 0) {
      host.replyBanner = { text: gateMsg, source: t("控制失败"), isError: true };
      host.render();
      return;
    }
    if (missingTargets.length > 0) {
      const isNotFoundOnly =
        gateFailure === null ||
        gateFailure.reason.code === "deviceNotFound" ||
        gateFailure.reason.code === "sceneNotFound";
      if (!isNotFoundOnly && gateMsg !== null) {
        host.replyBanner = { text: gateMsg, source: t("控制失败"), isError: true };
        host.render();
        return;
      }
      // Selecting another home under the same account swaps the device/scene list while keeping
      // the connection identity (ADR-0019 / HomeStore+Assistant.swift:628-633): park the timer in
      // missedScheduledCommands instead of failing or acting on the wrong home.
      if (!host.missedScheduledCommands.some((entry) => entry.id === item.id)) {
        const previous = host.missedScheduledCommands;
        host.missedScheduledCommands = [...previous, item];
        if (!host.scheduledCommandStore.persist()) {
          host.missedScheduledCommands = previous;
          host.replyBanner = {
            text: t("定时指令无法保存，请重试"),
            source: t("定时任务"),
            isError: true,
          };
          host.render();
          return;
        }
      }
      if (gateMsg !== null) {
        host.replyBanner = { text: gateMsg, source: t("控制失败"), isError: true };
      }
      host.isShowingAssistantBar = true;
      host.queueBackgroundRender();
      return;
    }
    const aliasedDevices = withAliases(host.layout, host.devices);
    const intents = IntentValidator.sanitize(item.intents, aliasedDevices, host.scenes);
    // A timer run is a multi-step write. Turning the timer switch off (or any later flip) must stop
    // the remaining steps before their next command; the ones already accepted keep their undo.
    const generation = scheduledCommandsGeneration(host);
    const completed = await host.executeIntents(
      intents,
      IntentReply.describe(intents, aliasedDevices, host.scenes),
      t("定时任务"),
      {
        recordHabits: false,
        userInitiated,
        allowWhileLocked,
        canContinue: () => isScheduledCommandsEnabled(host.settings) && scheduledCommandsGeneration(host) === generation,
      },
    );
    if (!completed && scheduledCommandsGeneration(host) !== generation) {
      host.replyBanner = { text: t("定时任务开关已改变，已停止剩余步骤"), source: t("定时任务"), isError: true };
      host.render();
    }
    return;
  }
  if (host.settings.connectionMode !== "demo" || isDualSourceEnabled(host)) {
    const disabledMsg = evaluateDisabledUtteranceGate({
      utterance: item.command,
      context: buildHostCapabilityContext(host),
      aliases: host.layout.aliases,
      languagePreference: host.settings.interfaceLanguage,
    });
    if (disabledMsg !== null) {
      host.replyBanner = { text: disabledMsg, source: t("控制失败"), isError: true };
      host.render();
      return;
    }
  }
  // An unresolved legacy timer must never be reinterpreted against a different home or AI response.
  host.replyBanner = { text: t("无法找到指令对应的设备"), source: t("定时任务"), isError: true };
  host.render();
}

export function learnShortcut(
    host: MenuMijiaWindowsApp,
    phrase: string,
    reply: string,
    intents: readonly DeviceIntent[],
  ): void {
    const clean = phrase.trim();
    if (clean.length < 2 || clean.length > 18) return;
    if (host.settings.learnedShortcuts.some((s) => s.phrase === clean)) return;
    host.settings.learnedShortcuts.unshift({
      phrase: clean,
      reply,
      intents,
      learnedAt: new Date().toISOString(),
    });
    if (host.settings.learnedShortcuts.length > 25) {
      host.settings.learnedShortcuts.length = 25;
    }
    host.saveSettings();
  }
