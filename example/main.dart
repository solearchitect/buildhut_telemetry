import 'package:flutter/material.dart';
import 'package:buildhut_telemetry/buildhut_telemetry.dart';

late final OtlpExporter exporter;
late final BuildhutExporterConfig exporterConfig;
late final BuildhutLogger logger;
late final FeatureFlagClient flags;

void main() {
  exporterConfig = BuildhutExporterConfig(
    endpoint: const String.fromEnvironment('BUILDHUT_ENDPOINT'),
    secret: const String.fromEnvironment('BUILDHUT_SECRET'),
    appName: 'buildhut-example',
    serviceVersion: '1.0.0',
  );

  exporter = OtlpExporter(exporterConfig)..start();
  logger = BuildhutLogger(exporter: exporter);

  flags = FeatureFlagClient(
    exporter: exporter,
    config: exporterConfig,
    gitBranch: const String.fromEnvironment('GIT_BRANCH'),
    version: '1.0.0',
  )..start();

  logger.info('Application starting');
  runApp(const ExampleApp());
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({super.key});

  @override
  State<ExampleApp> createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    logger.info('ExampleApp initialized');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      exporter.onAppBackgrounded();
    } else if (state == AppLifecycleState.resumed) {
      exporter.onAppForegrounded();
    }
    logger.info('Lifecycle changed', attributes: {
      'lifecycle.state': state.name,
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    exporter.close();
    flags.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BuildHut Telemetry Demo',
      theme: flags.isEnabled('dark-theme')
          ? ThemeData.dark()
          : ThemeData.light(),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final showNewHeader = flags.isEnabled('new-header');
    final showSearchV2 = flags.isEnabled(
      'search-v2',
      context: {'screen': 'home'},
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(showNewHeader ? 'BuildHut (v2)' : 'BuildHut'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Flags loaded: ${flags.isLoaded}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('Flag count: ${flags.allFlags.length}'),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => _doTracedWork(context),
              child: const Text('Run traced work'),
            ),
            if (showSearchV2) ...[
              const SizedBox(height: 24),
              const Text('Search V2 is enabled'),
              ElevatedButton(
                onPressed: () {
                  logger.info('Search V2 triggered');
                },
                child: const Text('Search'),
              ),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => flags.refresh(),
              child: const Text('Refresh flags'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _doTracedWork(BuildContext context) async {
    final tracer = SpanTracer(exporter: exporter);
    try {
      await tracer.withSpan('button.tap', (span) async {
        span.addEvent('pressed');

        await Future.delayed(const Duration(milliseconds: 150));

        // Check a flag inside a traced operation
        final useFastPath = flags.isEnabled(
          'fast-path',
          context: {'operation': 'traced-work'},
        );
        span.addEvent('flag_evaluated', attributes: {
          'feature_flag.fast_path': useFastPath,
        });

        if (useFastPath) {
          span.addEvent('fast_path_taken');
        } else {
          await Future.delayed(const Duration(milliseconds: 100));
          span.addEvent('slow_path_taken');
        }

        logger.info('Traced work completed', attributes: {
          'fast_path': useFastPath,
        });
      });
    } catch (e) {
      logger.error('Traced work failed', error: e);
    }
  }
}
