import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'routes/mobile_api.dart';
import 'utils/config.dart';

const _maxRequestBytes = 16 * 1024 * 1024;
const _hopByHopHeaders = {
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
};

Handler createHandler(ApiConfig config, {HttpClient? httpClient}) {
  final client = httpClient ?? HttpClient();
  final mobileApi =
      config.database == null
          ? null
          : MobileApi(config, config.database!, client);
  return Pipeline()
      .addMiddleware(_cors(config.allowedOrigins))
      .addHandler(
        (request) => _forwardRequest(request, config, client, mobileApi),
      );
}

Future<Response> _forwardRequest(
  Request request,
  ApiConfig config,
  HttpClient client,
  MobileApi? mobileApi,
) async {
  final requestPath =
      request.url.path.startsWith('/')
          ? request.url.path
          : '/${request.url.path}';
  final requestTarget =
      request.url.toString().startsWith('/')
          ? request.url.toString()
          : '/${request.url}';

  if (request.method == 'GET' &&
      const {'/', '/docs', '/docs/', '/docs.html'}.contains(requestPath)) {
    return _serveDocumentation('docs.html', 'text/html; charset=utf-8');
  }
  if (request.method == 'GET' &&
      const {'/openapi.yaml', '/docs/openapi.yaml'}.contains(requestPath)) {
    return _serveDocumentation(
      'openapi.yaml',
      'application/yaml; charset=utf-8',
    );
  }

  if (request.method == 'GET' && requestPath == '/api/health') {
    if (mobileApi != null) {
      return mobileApi.health();
    }
    return _json(200, {
      'success': true,
      'data': {
        'status': 'ok',
        'mobile_api_configured': config.database != null,
      },
    });
  }

  if (request.method == 'POST' &&
      requestPath.replaceFirst(RegExp(r'/+$'), '') == '/api/encomiendas') {
    if (mobileApi == null) {
      return _json(503, {
        'success': false,
        'message': 'La API móvil no tiene configurada la conexión MySQL',
      });
    }
    final authorizationResponse = await mobileApi.authorizeStaffPermission(
      request,
      'encomiendas.crear',
    );
    if (authorizationResponse != null) return authorizationResponse;
  }

  if (requestPath == '/api/auth/login' ||
      requestPath == '/api/auth/register' ||
      requestPath == '/api/auth/me' ||
      requestPath == '/api/auth/logout' ||
      requestPath.startsWith('/api/mobile/')) {
    if (mobileApi == null) {
      return _json(503, {
        'success': false,
        'message': 'La API móvil no tiene configurada la conexión MySQL',
      });
    }
    return mobileApi.handle(request);
  }

  if (!requestPath.startsWith('/api/')) {
    return _json(404, {'success': false, 'message': 'Endpoint not found'});
  }

  final suffix = requestTarget.substring('/api'.length);
  final upstreamUri = Uri.parse('${config.laravelApiUri}$suffix');
  final contentLength = int.tryParse(request.headers['content-length'] ?? '');
  if (contentLength != null && contentLength > _maxRequestBytes) {
    return _json(413, {
      'success': false,
      'message': 'Request body is too large',
    });
  }

  HttpClientRequest? pendingRequest;
  try {
    final upstreamRequest = await client
        .openUrl(request.method, upstreamUri)
        .timeout(const Duration(seconds: 10));
    pendingRequest = upstreamRequest;
    _copyRequestHeaders(request.headers, upstreamRequest.headers);
    if (contentLength != null) {
      upstreamRequest.contentLength = contentLength;
    }

    var receivedBytes = 0;
    await for (final chunk in request.read()) {
      receivedBytes += chunk.length;
      if (receivedBytes > _maxRequestBytes) {
        upstreamRequest.abort();
        return _json(413, {
          'success': false,
          'message': 'Request body is too large',
        });
      }
      upstreamRequest.add(chunk);
    }

    final upstreamResponse = await upstreamRequest.close().timeout(
      const Duration(seconds: 60),
    );
    final headers = <String, Object>{};
    upstreamResponse.headers.forEach((name, values) {
      if (!_hopByHopHeaders.contains(name.toLowerCase())) {
        headers[name] = values.length == 1 ? values.single : values;
      }
    });

    return Response(
      upstreamResponse.statusCode,
      body: upstreamResponse,
      headers: headers,
    );
  } on SocketException {
    pendingRequest?.abort();
    return _upstreamUnavailable();
  } on HttpException {
    pendingRequest?.abort();
    return _upstreamUnavailable();
  } on TimeoutException {
    pendingRequest?.abort();
    return _upstreamUnavailable();
  }
}

Future<Response> _serveDocumentation(
  String filename,
  String contentType,
) async {
  final file = File('public${Platform.pathSeparator}$filename');
  try {
    return Response.ok(
      await file.readAsBytes(),
      headers: {
        'content-type': contentType,
        'x-content-type-options': 'nosniff',
      },
    );
  } on FileSystemException catch (error, stackTrace) {
    stderr.writeln(
      'Unable to read API documentation $filename: $error\n$stackTrace',
    );
    return _json(500, {
      'success': false,
      'message': 'API documentation is unavailable.',
    });
  }
}

void _copyRequestHeaders(Map<String, String> source, HttpHeaders destination) {
  source.forEach((name, value) {
    final normalized = name.toLowerCase();
    if (normalized != 'host' &&
        normalized != 'content-length' &&
        !_hopByHopHeaders.contains(normalized)) {
      destination.set(name, value);
    }
  });
}

Response _upstreamUnavailable() =>
    _json(502, {'success': false, 'message': 'The Laravel API is unavailable'});

Middleware _cors(Set<String> allowedOrigins) => (Handler innerHandler) {
  return (Request request) async {
    final origin = request.headers['origin'];
    final isLocalDevelopmentOrigin =
        origin != null &&
        (Uri.tryParse(origin)?.host == 'localhost' ||
            Uri.tryParse(origin)?.host == '127.0.0.1');
    final allowed =
        origin != null &&
        (allowedOrigins.contains('*') ||
            allowedOrigins.contains(origin) ||
            isLocalDevelopmentOrigin);
    final headers = <String, String>{
      'Vary': 'Origin',
      if (allowed) 'Access-Control-Allow-Origin': origin,
      if (allowed)
        'Access-Control-Allow-Methods':
            'GET, POST, PUT, PATCH, DELETE, OPTIONS',
      if (allowed)
        'Access-Control-Allow-Headers':
            'Authorization, Content-Type, Accept, X-Account-Type, X-Requested-With',
      if (allowed) 'Access-Control-Expose-Headers': 'Authorization',
      if (allowed) 'Access-Control-Max-Age': '600',
    };
    if (request.method == 'OPTIONS') {
      return Response(204, headers: headers);
    }
    final response = await innerHandler(request);
    return response.change(headers: {...response.headers, ...headers});
  };
};

Response _json(int status, Object body) => Response(
  status,
  body: jsonEncode(body),
  headers: const {'content-type': 'application/json; charset=utf-8'},
);

Future<void> runServer() async {
  final config = ApiConfig.load();
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  final address = await _bindAddress(config.host);
  final server = await shelf_io.serve(
    createHandler(config, httpClient: client),
    address,
    config.port,
  );
  stdout.writeln(
    'Sistema Valle API gateway listening on ${server.address.address}:${server.port}',
  );
  try {
    await ProcessSignal.sigint.watch().first;
  } finally {
    client.close(force: true);
    await server.close(force: true);
  }
}

Future<InternetAddress> _bindAddress(String host) async {
  if (host == '0.0.0.0') return InternetAddress.anyIPv4;
  if (host == '::') return InternetAddress.anyIPv6;
  final addresses = await InternetAddress.lookup(host);
  if (addresses.isEmpty) {
    throw const FormatException('HOST did not resolve to an IP address');
  }
  return addresses.first;
}
