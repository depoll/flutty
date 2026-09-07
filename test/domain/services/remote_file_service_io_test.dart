import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:monkeyssh/domain/services/remote_file_service.dart';

class _MockSftpClient extends Mock implements SftpClient {}

class _MockSftpFile extends Mock implements SftpFile {}

void main() {
  late Directory directory;
  late _MockSftpClient sftp;
  late _MockSftpFile remoteFile;
  const service = RemoteFileService();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('remote-file-test-');
    sftp = _MockSftpClient();
    remoteFile = _MockSftpFile();
    when(() => sftp.open('/remote/file')).thenAnswer((_) async => remoteFile);
    when(() => remoteFile.close()).thenAnswer((_) async {});
  });

  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'closes the remote handle when the local download cannot open',
    () async {
      when(
        () => remoteFile.read(),
      ).thenAnswer((_) => Stream.value(Uint8List.fromList([1, 2, 3])));

      await expectLater(
        service.downloadFile(
          sftp: sftp,
          remotePath: '/remote/file',
          localPath: '${directory.path}/missing/file',
        ),
        throwsA(isA<FileSystemException>()),
      );

      verify(() => remoteFile.close()).called(1);
    },
  );

  test('closes the remote handle when the download stream fails', () async {
    final failure = SftpStatusError(SftpStatusCode.failure, 'read failed');
    when(
      () => remoteFile.read(),
    ).thenAnswer((_) => Stream<Uint8List>.error(failure));

    await expectLater(
      service.downloadFile(
        sftp: sftp,
        remotePath: '/remote/file',
        localPath: '${directory.path}/file',
      ),
      throwsA(same(failure)),
    );

    verify(() => remoteFile.close()).called(1);
  });

  test('downloads all chunks and closes the remote handle', () async {
    when(() => remoteFile.read()).thenAnswer(
      (_) => Stream.fromIterable([
        Uint8List.fromList([0, 1, 255]),
        Uint8List.fromList([2, 3]),
      ]),
    );
    final file = File('${directory.path}/file');

    await service.downloadFile(
      sftp: sftp,
      remotePath: '/remote/file',
      localPath: file.path,
    );

    expect(await file.readAsBytes(), [0, 1, 255, 2, 3]);
    verify(() => remoteFile.close()).called(1);
  });
}
