// Synthetic completed-search evidence; this helper never accesses the network.
export function unmatchedDiscoveryResponse() {
  return { status: "completed", output: [
    { type: "web_search_call", status: "completed", action: { type: "search", query: "fixture garment label", sources: [] } },
    { type: "message", role: "assistant", content: [{ type: "output_text",
      text: JSON.stringify({ brand: null, facts: [], nextQuery: "" }) }] },
  ] };
}
