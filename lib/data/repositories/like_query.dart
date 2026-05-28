/// Escape character used for repository SQL LIKE clauses.
const sqlLikeEscapeCharacter = r'\';

/// Escapes SQLite LIKE metacharacters in [query] for literal substring search.
String escapeSqlLikeQuery(String query) => query
    .replaceAll(
      sqlLikeEscapeCharacter,
      '$sqlLikeEscapeCharacter$sqlLikeEscapeCharacter',
    )
    .replaceAll('%', '$sqlLikeEscapeCharacter%')
    .replaceAll('_', '${sqlLikeEscapeCharacter}_');
