import 'package:path/path.dart' as p;

/// Maps common file extensions to highlight.js language identifiers.
///
/// Returns `null` when no mapping exists, allowing the caller to fall back to
/// auto-detection via `highlight.parse(code)`.
String? detectLanguageFromFilename(String filename) {
  final ext = p.extension(filename).toLowerCase();
  if (ext.isEmpty) {
    return _filenameLanguages[filename.toLowerCase()];
  }
  return _extensionLanguages[ext];
}

const _extensionLanguages = <String, String>{
  // Web
  '.html': 'xml',
  '.htm': 'xml',
  '.xml': 'xml',
  '.svg': 'xml',
  '.xsl': 'xml',
  '.css': 'css',
  '.scss': 'scss',
  '.less': 'less',
  '.js': 'javascript',
  '.mjs': 'javascript',
  '.cjs': 'javascript',
  '.jsx': 'javascript',
  '.ts': 'typescript',
  '.tsx': 'typescript',

  // Data / config
  '.json': 'json',
  '.yaml': 'yaml',
  '.yml': 'yaml',
  '.toml': 'ini',
  '.ini': 'ini',
  '.cfg': 'ini',
  '.conf': 'nginx',
  '.properties': 'properties',

  // Shell / scripting
  '.sh': 'bash',
  '.bash': 'bash',
  '.zsh': 'bash',
  '.fish': 'bash',
  '.ps1': 'powershell',
  '.bat': 'dos',
  '.cmd': 'dos',

  // Systems
  '.c': 'c',
  '.h': 'c',
  '.cpp': 'cpp',
  '.cxx': 'cpp',
  '.cc': 'cpp',
  '.hpp': 'cpp',
  '.hxx': 'cpp',
  '.m': 'objectivec',
  '.mm': 'objectivec',
  '.rs': 'rust',
  '.go': 'go',
  '.zig': 'zig',
  '.asm': 'x86asm',
  '.s': 'x86asm',

  // JVM
  '.java': 'java',
  '.kt': 'kotlin',
  '.kts': 'kotlin',
  '.scala': 'scala',
  '.groovy': 'groovy',
  '.gradle': 'groovy',
  '.clj': 'clojure',

  // .NET
  '.cs': 'csharp',
  '.fs': 'fsharp',
  '.vb': 'vbnet',

  // Mobile / cross-platform
  '.dart': 'dart',
  '.swift': 'swift',

  // Scripting
  '.py': 'python',
  '.rb': 'ruby',
  '.pl': 'perl',
  '.pm': 'perl',
  '.lua': 'lua',
  '.r': 'r',
  '.R': 'r',
  '.php': 'php',
  '.tcl': 'tcl',
  '.ex': 'elixir',
  '.exs': 'elixir',
  '.erl': 'erlang',
  '.hrl': 'erlang',
  '.hs': 'haskell',
  '.lhs': 'haskell',
  '.ml': 'ocaml',
  '.mli': 'ocaml',
  '.jl': 'julia',
  '.nim': 'nim',

  // Markup / documentation
  '.md': 'markdown',
  '.markdown': 'markdown',
  '.tex': 'latex',
  '.rst': 'plaintext',

  // Database
  '.sql': 'sql',

  // DevOps / infra
  '.dockerfile': 'dockerfile',
  '.tf': 'hcl',
  '.hcl': 'hcl',
  '.cmake': 'cmake',

  // Misc
  '.diff': 'diff',
  '.patch': 'diff',
  '.makefile': 'makefile',
  '.mk': 'makefile',
  '.proto': 'protobuf',
  '.graphql': 'graphql',
  '.gql': 'graphql',
};

const _filenameLanguages = <String, String>{
  'dockerfile': 'dockerfile',
  'makefile': 'makefile',
  'cmakelists.txt': 'cmake',
  'gemfile': 'ruby',
  'rakefile': 'ruby',
  'vagrantfile': 'ruby',
  '.bashrc': 'bash',
  '.bash_profile': 'bash',
  '.zshrc': 'bash',
  '.profile': 'bash',
  '.gitignore': 'bash',
  '.env': 'bash',
};
