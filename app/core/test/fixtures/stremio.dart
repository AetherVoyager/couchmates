/// Responses shaped like Telegram-Stremio's (Backend/fastapi/routes/
/// stremio_routes.py): years and ratings as text, empty strings for missing
/// values, and notices mixed into the stream list.
library;

const manifest = {
  'id': 'telegram.media.abcd1234',
  'version': '3.1.0',
  'name': 'Telegram',
  'types': ['movie', 'series'],
  'resources': ['catalog', 'meta', 'stream', 'subtitles'],
  'catalogs': [
    {
      'type': 'movie',
      'id': 'latest_movies',
      'name': 'Recently Added',
      'extra': [
        {
          'name': 'genre',
          'isRequired': false,
          'options': ['Action', 'Drama'],
        },
        {'name': 'skip'},
      ],
      'extraSupported': ['genre', 'skip'],
    },
    {
      'type': 'series',
      'id': 'top_series',
      'name': 'Popular',
      'extra': [
        {'name': 'skip'},
        {'name': 'search', 'isRequired': false},
      ],
      'extraSupported': ['skip', 'search'],
    },
  ],
  'idPrefixes': ['tt', 'tg', 'kitsu'],
};

const catalogItem = {
  'id': 'tt1375666',
  'type': 'movie',
  'name': 'Inception',
  'poster': 'https://img.example/p.jpg',
  'logo': '',
  'year': '2010',
  'releaseInfo': '2010',
  'imdb_id': 'tt1375666',
  'moviedb_id': 27205,
  'background': 'https://img.example/b.jpg',
  'genres': ['Action', 'Sci-Fi'],
  'imdbRating': '8.8',
  'description': 'A thief who steals corporate secrets…',
  'cast': <String>[],
  'runtime': '',
};

const seriesMeta = {
  'meta': {
    'id': 'tt0903747',
    'type': 'series',
    'name': 'Breaking Bad',
    'description': 'A chemistry teacher…',
    'year': '2008-2013',
    'imdbRating': '',
    'genres': ['Drama'],
    'poster': 'https://img.example/bb.jpg',
    'logo': '',
    'background': '',
    'releaseInfo': '2008-2013',
    'moviedb_id': '',
    'cast': <String>[],
    'runtime': '',
    'videos': [
      {
        'id': 'tt0903747:2:1',
        'title': 'Seven Thirty-Seven',
        'season': 2,
        'episode': 1,
        'overview': 'No description available for this episode yet.',
        'released': '2009-03-08T00:00:00+00:00',
        'thumbnail': 'https://img.example/e.jpg',
        'imdb_id': 'tt0903747',
      },
      {'id': 'tt0903747:1:2', 'title': 'E02', 'season': 1, 'episode': 2, 'released': '2008-01-27T00:00:00Z'},
      {'id': 'tt0903747:1:1', 'title': 'Pilot', 'season': 1, 'episode': 1, 'released': '2008-01-20T00:00:00Z'},
      {'id': 'tt0903747:0:1', 'title': 'Combined 1', 'season': 0, 'episode': 1},
    ],
  },
};

const streams = {
  'streams': [
    {
      'name': 'Telegram 1080p WEB-DL (Cloudflare)',
      'title': '📁 Inception.2010.1080p.mkv\n💾 1.5 GB',
      'url': 'https://tg.example.com/dl/tok/42/video.mkv?via=cf',
      'size_bytes': 1610612736,
      'episode_start': 0,
      'name_key': '',
      'sort_name': 'Telegram 1080p WEB-DL',
      'behaviorHints': {'bingeGroup': 'telegram-stremio-1080p-cloudflare'},
    },
    {'name': 'Limit Reached', 'title': 'Daily limit used up.', 'url': 'tg://user?id=1'},
    {
      'name': '❤ Support',
      'title': 'Enjoying Telegram Stremio?',
      'description': 'Enjoying Telegram Stremio?',
      'externalUrl': 'https://donate.example',
    },
  ],
};

const planExpired = {
  'streams': [
    {'name': '🚫 Plan Expired', 'title': 'Renew to keep watching.', 'url': 'https://t.me/somebot'},
  ],
};
