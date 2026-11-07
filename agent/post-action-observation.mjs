// Check action-bound observations before reusing them instead of a fresh MCP read.
// "sent: true" alone must not be treated as task success or verified UI state.
export function reusableActionObservation(receipt, device, expectedBundleId = null, now = Date.now()) {
  if (!receipt || receipt.sent !== true || receipt.isError || receipt.stopped || receipt.outcome === 'unknown') return null;
  const data = receipt.post_action_observation;
  if (data?.version !== 1 || typeof receipt.receipt_id !== 'string' ||
      !receipt.receipt_id || data.action_receipt_id !== receipt.receipt_id) return null;
  const observation = data.observation;
  if (!observation || observation.device !== device || typeof observation.id !== 'string' || !observation.id ||
      !Number.isSafeInteger(observation.revision) || observation.revision < 0 || observation.atomic !== false) return null;
  const inputEnded = Date.parse(receipt.input_completed_at);
  const captured = Date.parse(observation.capture_started_at);
  const completed = Date.parse(observation.capture_completed_at);
  const structured = Date.parse(observation.structure_completed_at);
  if (![inputEnded, captured, completed, structured].every(Number.isFinite) ||
      inputEnded > captured || captured > completed || completed > structured ||
      structured > now + 1000 || now - captured > 25000 || now - captured < -1000) return null;
  if (data.source !== 'accessibility' || data.truncated !== false ||
      !Array.isArray(data.elements) || data.elements.length === 0 || data.elements.length > 400 ||
      data.total !== data.elements.length || data.prompt?.status !== 'checked' || data.prompt.warning) return null;
  if (expectedBundleId && data.foreground?.bundle_id !== expectedBundleId) return null;
  if (!data.elements.every(element => element && typeof element.ref === 'string' && /^e\d+$/.test(element.ref)) ||
      new Set(data.elements.map(element => element.ref)).size !== data.elements.length) return null;
  return {
    observation, source: data.source, foreground: data.foreground,
    elements: data.elements, total: data.total, truncated: false, prompt: data.prompt,
  };
}
