import 'package:dartssh2/dartssh2.dart';

const _channelUploadLoopFrame = 'SSHChannelController._uploadLoop';

/// Whether [error] is a late channel write after the SSH transport closed.
///
/// dartssh2 starts channel upload loops internally without exposing their
/// futures. A transport disconnect can therefore race a queued write and reach
/// the platform error handler even though the connection shutdown is expected.
bool isExpectedSshChannelTeardownError(Object error, StackTrace stackTrace) =>
    error is SSHStateError &&
    stackTrace.toString().contains(_channelUploadLoopFrame);
