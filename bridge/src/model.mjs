import { join } from 'node:path';
import { BridgeError, hash, readJSON } from './util.mjs';

export const SUPPORTED_MODES = ['build', 'plan', 'edit', 'yolo'];
export function modelCatalog(zcodeRoot) {
  const providers = readJSON(join(zcodeRoot, 'v2/config.json')).provider ?? {};
  return Object.entries(providers).flatMap(([providerId, source]) => Object.entries(source.models ?? {}).filter(([, raw]) => !raw.zcode?.deleted).map(([modelId, raw]) => {
    const isGLM53 = /glm-5\.3(?![0-9])/i.test(modelId);
    const thoughtLevels = isGLM53 ? ['low', 'high', 'max'] : raw.reasoning?.variants ?? [];
    const unavailableReason = source.enabled === false ? 'provider_disabled' : !source.options?.baseURL ? 'provider_runtime_unverified' : !isGLM53 && (raw.reasoning?.enabled || thoughtLevels.length) ? 'model_mapping_unverified' : undefined;
    return { providerId, providerName: source.name ?? providerId, modelId, name: raw.name ?? modelId, available: !unavailableReason,
      ...(unavailableReason ? { unavailableReason } : {}), supportsImages: raw.modalities?.input?.includes('image') ?? false, supportsPDF: raw.modalities?.input?.includes('pdf') || raw.zcode?.supportsPdf === true,
      supportsTools: raw.zcode?.supportsTools ?? true, thoughtLevels, defaultThoughtLevel: isGLM53 ? 'max' : raw.reasoning?.defaultVariant,
      contextWindow: raw.limit?.context, maxOutputTokens: raw.limit?.output };
  }));
}

export function validateSelection(zcodeRoot, selection) {
  if (!selection || typeof selection.providerId !== 'string' || typeof selection.modelId !== 'string') throw new BridgeError(422, 'model_unconfigured', 'Choose an available model before creating a task.');
  const model = modelCatalog(zcodeRoot).find(model => model.providerId === selection.providerId && model.modelId === selection.modelId);
  if (!model || !model.available) throw new BridgeError(422, model?.unavailableReason ?? 'model_unavailable', 'This model cannot currently be used by the mobile bridge.', false, { providerId: selection.providerId, modelId: selection.modelId });
  if (selection.thoughtLevel && !model.thoughtLevels.includes(selection.thoughtLevel)) throw new BridgeError(422, 'thought_level_unsupported', 'This thinking level is not supported by the selected model.', false, { thoughtLevels: model.thoughtLevels });
  return { providerId: selection.providerId, modelId: selection.modelId, ...(selection.thoughtLevel || model.defaultThoughtLevel ? { thoughtLevel: selection.thoughtLevel || model.defaultThoughtLevel } : {}) };
}

// Credentials stay in this process and the child stdio pipe; they never enter an HTTP DTO.
export function selectedRuntimeModel(zcodeRoot, selection) {
  const providers = readJSON(join(zcodeRoot, 'v2/config.json')).provider ?? {};
  if (!selection?.providerId || !selection.modelId) throw new BridgeError(422, 'model_unconfigured', 'Choose a model in ZCode before creating a mobile task.');
  const source = providers[selection.providerId], raw = source?.models?.[selection.modelId];
  if (!source || !raw || source.enabled === false || raw.zcode?.deleted) throw new BridgeError(422, 'model_unavailable', 'The selected desktop model is unavailable. Select an available model in ZCode.');
  const options = source.options ?? {};
  const model = { modelId: selection.modelId, label: raw.name || selection.modelId, contextWindow: raw.limit?.context, maxOutputTokens: raw.limit?.output,
    supportsImages: raw.modalities?.input?.includes('image') ?? false, supportsPdf: raw.modalities?.input?.includes('pdf') || raw.zcode?.supportsPdf === true, supportsTools: raw.zcode?.supportsTools ?? true };
  // This is the bundled GLM 5.3 mapping: low/high/max -> openaiCompatible.reasoningEffort.
  // The selected value comes from ZCode's persisted runtime/model_selection entry.
  if (/glm-5\.3(?![0-9])/i.test(selection.modelId)) {
    const levels = ['low', 'high', 'max'];
    model.reasoning = { enabled: true, levels: levels.map(value => ({ value, label: value })), defaultLevel: 'max',
      providerOptionsByLevel: Object.fromEntries(levels.map(level => [level, source.kind === 'anthropic'
        ? { anthropic: { effort: level, thinking: { type: 'enabled', budgetTokens: { low: 1024, high: 16384, max: 32768 }[level] } } }
        : { openaiCompatible: { reasoningEffort: level } }])) };
  } else if (selection.thoughtLevel) {
    // Unsupported mappings are surfaced rather than silently reducing thinking.
    throw new BridgeError(422, 'model_mapping_unverified', `Thinking-level mapping for ${selection.modelId} has not been verified by this bridge.`);
  }
  const provider = { providerId: selection.providerId, kind: source.kind, label: source.name, source: 'custom',
    baseURL: options.baseURL, apiKeyRequired: options.apiKeyRequired, ...(options.apiKey ? { apiKey: { source: 'inline', value: options.apiKey } } : {}),
    ...(options.headers ? { headers: options.headers } : {}), ...(source.apiFormat ? { apiFormat: source.apiFormat } : {}), models: [model] };
  return { revision: `mobile-runtime:${hash(JSON.stringify({ provider, thoughtLevel: selection.thoughtLevel })).slice(0, 24)}`,
    generatedAt: Date.now(), model: { providerId: selection.providerId, modelId: selection.modelId }, provider,
    ...(selection.thoughtLevel ? { thoughtLevel: selection.thoughtLevel } : {}) };
}
