/// Bidirectional byte transport used by an ACP JSON-RPC connection.
abstract interface class AcpTransport {
  /// Bytes received from the remote ACP peer.
  Stream<List<int>> get incoming;

  /// Writes a complete sequence of bytes to the remote peer.
  Future<void> write(List<int> bytes);

  /// Closes the transport and releases all resources.
  Future<void> close();
}
