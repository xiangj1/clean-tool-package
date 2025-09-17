import 'dart:io';

import 'package:photo_clean_cli/photo_clean_cli.dart' as cli;

Future<void> main(List<String> args) async {
  final code = await cli.runCli(args);
  exit(code);
}
