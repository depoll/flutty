class EscapeEmitter {
  const EscapeEmitter();

  String primaryDeviceAttributes() {
    return '\x1b[?1;2c';
  }

  String secondaryDeviceAttributes() {
    const model = 0;
    const version = 0;
    return '\x1b[>$model;$version;0c';
  }

  String tertiaryDeviceAttributes() {
    return '\x1bP!|00000000\x1b\\';
  }

  /// Response to XTVERSION (`CSI > q`): the terminal name and version.
  ///
  /// MonkeySSH implements the kitty graphics and keyboard protocols (plus
  /// truecolor and styled underlines), so it reports a kitty-family identity.
  /// Besides being accurate about the supported protocol family, this unlocks
  /// the richer rendering path in CLIs (for example the GitHub Copilot CLI)
  /// that gate full-width prompt/composer backgrounds on a recognized
  /// XTVERSION name. The version predates the kitty text-sizing protocol, which
  /// this terminal does not implement.
  String terminalVersion() {
    return '\x1bP>|kitty(0.32.0)\x1b\\';
  }

  String operatingStatus() {
    return '\x1b[0n';
  }

  String cursorPosition(int x, int y) {
    return '\x1b[$y;${x}R';
  }

  String bracketedPaste(String text) {
    return '\x1b[200~$text\x1b[201~';
  }

  String size(int rows, int cols) {
    return '\x1b[8;$rows;${cols}t';
  }
}
