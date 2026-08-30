import 'package:dartssh2/dartssh2.dart';

const _channelUploadLoopFrame = 'SSHChannelController._uploadLoop';
const _channelCloseFrame = 'SSHChannelController._sendEOFIfNeeded';

/// Whether [error] is a late channel write after the SSH transport closed.
///
/// dartssh2 starts channel upload loops internally without exposing their
/// futures. A transport disconnect can therefore race a queued write and reach
/// the platform error handler. Closing a channel after the same disconnect can
/// also try to send EOF over the closed transport. Both are expected teardown.
bool isExpectedSshChannelTeardownError(Object error, StackTrace stackTrace) =>
    error is SSHStateError &&
    (_containsFrame(stackTrace, _channelUploadLoopFrame) ||
        _containsFrame(stackTrace, _channelCloseFrame));

/// Whether [error] is an operational SSH or SFTP failure.
///
/// dartssh2 models these as interface types rather than [Exception], so an
/// `on Exception` clause does not catch them.
bool isExpectedSshOperationError(Object error) =>
    error is SSHError || error is SftpError;

bool _containsFrame(StackTrace stackTrace, String frame) =>
    stackTrace.toString().contains(frame);
