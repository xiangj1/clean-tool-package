import 'dart:io';

import 'package:photo_clean_cli/photo_clean_cli.dart' as cli;

Future<void> main(List<String> args) async {
  final exitCodeValue = await cli.runCli(args);
  exit(exitCodeValue);
}
