import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:sistemavalle_api/routes/mobile_api.dart';
import 'package:sistemavalle_api/server.dart';
import 'package:sistemavalle_api/utils/config.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer upstream;
  late HttpClient client;
  late Handler handler;
  late Completer<HttpRequest> upstreamCompleter;
  late Future<HttpRequest> upstreamRequest;

  setUp(() async {
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = HttpClient();
    upstreamCompleter = Completer<HttpRequest>();
    upstream.listen((request) {
      if (!upstreamCompleter.isCompleted) {
        upstreamCompleter.complete(request);
      }
    });
    upstreamRequest = upstreamCompleter.future;
    final config = ApiConfig.fromEnvironment({
      'LARAVEL_API_URL': 'http://127.0.0.1:${upstream.port}/api',
      'CORS_ALLOWED_ORIGINS': 'https://mobile.example',
    });
    handler = createHandler(config, httpClient: client);
  });

  tearDown(() async {
    client.close(force: true);
    await upstream.close(force: true);
  });

  test(
    'forwards request path, query, authorization and body to Laravel',
    () async {
      final responseFuture = handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/clientes?source=flutter'),
          headers: {
            'authorization': 'Bearer sample-token',
            'content-type': 'application/json',
          },
          body: '{"email":"person@example.com"}',
        ),
      );

      final received = await upstreamRequest.timeout(
        const Duration(seconds: 2),
      );
      final receivedBody = await utf8.decoder.bind(received).join();
      expect(received.uri.path, '/api/clientes');
      expect(received.uri.queryParameters['source'], 'flutter');
      expect(received.headers.value('authorization'), 'Bearer sample-token');
      expect(receivedBody, '{"email":"person@example.com"}');
      received.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"success":true,"data":{"account_type":"staff"}}')
        ..close();

      final response = await responseFuture;
      expect(response.statusCode, 200);
      expect(jsonDecode(await response.readAsString()), {
        'success': true,
        'data': {'account_type': 'staff'},
      });
    },
  );

  test('health uses the success envelope without proxying', () async {
    final response = await handler(
      Request('GET', Uri.parse('http://localhost/api/health')),
    );
    expect(response.statusCode, 200);
    expect(jsonDecode(await response.readAsString()), {
      'success': true,
      'data': {'status': 'ok', 'mobile_api_configured': false},
    });
  });

  test('mobile endpoints report when MySQL is not configured', () async {
    final response = await handler(
      Request('GET', Uri.parse('http://localhost/api/mobile/viajes')),
    );
    expect(response.statusCode, 503);
    expect(jsonDecode(await response.readAsString()), {
      'success': false,
      'message': 'La API móvil no tiene configurada la conexión MySQL',
    });
  });

  test('client registration is handled by the mobile API', () async {
    final response = await handler(
      Request(
        'POST',
        Uri.parse('http://localhost/api/auth/register'),
        body: '{}',
      ),
    );
    expect(response.statusCode, 503);
    expect(jsonDecode(await response.readAsString()), {
      'success': false,
      'message': 'La API móvil no tiene configurada la conexión MySQL',
    });
  });

  test(
    'encomienda creation is not proxied without configured auth database',
    () async {
      final response = await handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/encomiendas'),
          body: '{"destinatario_nombre":"Cliente"}',
        ),
      );

      expect(response.statusCode, 503);
      expect(jsonDecode(await response.readAsString()), {
        'success': false,
        'message': 'La API móvil no tiene configurada la conexión MySQL',
      });
    },
  );

  test('loads the mobile database settings without exposing credentials', () {
    final config = ApiConfig.fromEnvironment({
      'LARAVEL_API_URL': 'http://127.0.0.1:8000/api',
      'DB_HOST': '127.0.0.1',
      'DB_PORT': '3306',
      'DB_DATABASE': 'pvalle',
      'DB_USERNAME': 'mobile_user',
      'DB_PASSWORD': '',
    });

    expect(config.database?.host, '127.0.0.1');
    expect(config.database?.port, 3306);
    expect(config.database?.database, 'pvalle');
    expect(config.database?.password, isEmpty);
  });

  test(
    'streams multipart comprobantes to Laravel with the original length',
    () async {
      const body = '--form-boundary\r\nfile contents\r\n--form-boundary--\r\n';
      final responseFuture = handler(
        Request(
          'POST',
          Uri.parse('http://localhost/api/cliente/reservas/9/comprobante'),
          headers: {
            'authorization': 'Bearer customer-token',
            'content-type': 'multipart/form-data; boundary=form-boundary',
            'content-length': body.length.toString(),
          },
          body: body,
        ),
      );

      final received = await upstreamRequest.timeout(
        const Duration(seconds: 2),
      );
      final receivedBody = await utf8.decoder.bind(received).join();
      expect(received.uri.path, '/api/cliente/reservas/9/comprobante');
      expect(received.headers.contentLength, body.length);
      expect(receivedBody, body);
      received.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"success":true}')
        ..close();

      final response = await responseFuture;
      expect(response.statusCode, 200);
    },
  );

  test('preflight allows only configured Flutter web origins', () async {
    final response = await handler(
      Request(
        'OPTIONS',
        Uri.parse('http://localhost/api/reservas'),
        headers: {'origin': 'https://mobile.example'},
      ),
    );
    expect(response.statusCode, 204);
    expect(
      response.headers['access-control-allow-origin'],
      'https://mobile.example',
    );
    final denied = await handler(
      Request(
        'OPTIONS',
        Uri.parse('http://localhost/api/reservas'),
        headers: {'origin': 'https://other.example'},
      ),
    );
    expect(denied.headers.containsKey('access-control-allow-origin'), isFalse);
  });

  test('extracts staff login payload from direct Laravel responses', () {
    final payload = MobileApi.extractStaffLoginPayload({
      'token': 'secret-token',
      'user': {'id': 7, 'name': 'Ana', 'email': 'ana@example.com'},
    });

    expect(payload, {
      'token': 'secret-token',
      'user': {'id': 7, 'name': 'Ana', 'email': 'ana@example.com'},
    });

    final wrapped = MobileApi.extractStaffLoginPayload({
      'success': true,
      'data': {
        'token': 'wrapped-token',
        'user': {'id': 8, 'name': 'Luis', 'email': 'luis@example.com'},
      },
    });

    expect(wrapped, {
      'token': 'wrapped-token',
      'user': {'id': 8, 'name': 'Luis', 'email': 'luis@example.com'},
    });
  });

  test(
    'serves the ReDoc page and OpenAPI specification without proxying',
    () async {
      for (final path in ['/', '/docs', '/docs/']) {
        final docsResponse = await handler(
          Request('GET', Uri.parse('http://localhost$path')),
        );
        final docs = await docsResponse.readAsString();
        expect(docsResponse.statusCode, 200, reason: path);
        expect(
          docsResponse.headers['content-type'],
          'text/html; charset=utf-8',
        );
        expect(docs, contains('<redoc spec-url="/openapi.yaml"></redoc>'));
        expect(
          docs,
          contains(
            'https://cdn.redoc.ly/redoc/v2.1.5/bundles/redoc.standalone.js',
          ),
        );
      }

      final specResponse = await handler(
        Request('GET', Uri.parse('http://localhost/openapi.yaml')),
      );
      final spec = await specResponse.readAsString();
      expect(specResponse.statusCode, 200);
      expect(
        specResponse.headers['content-type'],
        'application/yaml; charset=utf-8',
      );
      expect(spec, contains('openapi: 3.0.3'));
      expect(spec, contains('### Administrador'));
      expect(spec, contains('### Recepcionista'));
      expect(spec, contains('### Cliente'));
      for (final path in [
        '/api/buses/{bus}:',
        '/api/clientes/{cliente}:',
        '/api/conductores/{conductor}:',
        '/api/rutas/{ruta}:',
        '/api/tipoencomiendas/{tipoencomienda}:',
        '/api/tipoincidencias/{tipoincidencia}:',
        '/api/viajes/{viaje}:',
        '/api/reservas/{reserva}:',
        '/api/boletos/{boleto}:',
        '/api/encomiendas/{encomienda}:',
        '/api/notificaciones/{notificacion}:',
        '/api/incidenciasviaje/{incidenciaviaje}:',
        '/api/asientosviaje/{asientoviaje}:',
        '/api/asignacionesconductor/{asignacionconductor}:',
        '/api/mobile/reservas/{reservaId}/comprobante:',
      ]) {
        expect(spec, contains(path), reason: 'Missing documented path $path');
      }
      expect(upstreamCompleter.isCompleted, isFalse);
    },
  );

  test('non-API paths are not exposed by the gateway', () async {
    final response = await handler(
      Request('GET', Uri.parse('http://localhost/admin/users')),
    );
    expect(response.statusCode, 404);
    expect(jsonDecode(await response.readAsString()), {
      'success': false,
      'message': 'Endpoint not found',
    });
  });
}
