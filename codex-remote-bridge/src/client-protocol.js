// Phone-facing v1 contract. Keep existing fields stable; additions are optional.
// Both runtime initialization and the warm Bridge shortcut use this definition.
const CONTROL_PROTOCOL_VERSION = 1;

function buildClientHandshake({ mode, endpoint = '', platform = process.platform,
  bridgeManaged = false, claudeChannels = false } = {}) {
  const shared = mode === 'shared';
  return {
    bridgeManaged,
    claudeChannels,
    sharedSession: shared,
    controlProtocol: shared ? CONTROL_PROTOCOL_VERSION : 0,
    sessionSettings: shared,
    turnStateSnapshot: shared,
    macTerminalOpen: shared && platform === 'darwin' && endpoint.startsWith('unix://'),
  };
}

module.exports = { CONTROL_PROTOCOL_VERSION, buildClientHandshake };
