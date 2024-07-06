import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screenshot/screenshot.dart';
import 'package:camera_windows/camera_windows.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: TimerScreen(),
    );
  }
}

class TimerScreen extends StatefulWidget {
  @override
  _TimerScreenState createState() => _TimerScreenState();
}

class _TimerScreenState extends State<TimerScreen> {
  String _cameraInfo = 'Unknown';
  List<CameraDescription> _cameras = <CameraDescription>[];
  int _cameraIndex = 0;
  int _cameraId = -1;
  bool _initialized = false;
  Size? _previewSize;
  final MediaSettings _mediaSettings = const MediaSettings(
    resolutionPreset: ResolutionPreset.medium,
    fps: 15,
    videoBitrate: 200000,
    audioBitrate: 32000,
    enableAudio: true,
  );
  StreamSubscription<CameraErrorEvent>? _errorStreamSubscription;
  StreamSubscription<CameraClosingEvent>? _cameraClosingStreamSubscription;

  Timer? _timer;
  int _seconds = 0;
  ScreenshotController screenshotController = ScreenshotController();
  bool isCameraInitialized = false;
  File? screenshotFile;
  XFile? headshotFile;
  bool _isTimerRunning = false;

  @override
  void initState() {
    super.initState();
    WidgetsFlutterBinding.ensureInitialized();
    _fetchCamera();
  }

  @override
  void dispose() {
    _disposeCurrentCamera();
    _errorStreamSubscription?.cancel();
    _errorStreamSubscription = null;
    _cameraClosingStreamSubscription?.cancel();
    _cameraClosingStreamSubscription = null;
    super.dispose();
  }

  Future<void> _fetchCamera() async {
    String cameraInfo;
    List<CameraDescription> cameras = <CameraDescription>[];

    int cameraIndex = 0;
    try {
      cameras = await CameraPlatform.instance.availableCameras();
      if (cameras.isEmpty) {
        cameraInfo = 'No available cameras';
      } else {
        cameraIndex = _cameraIndex % cameras.length;
        cameraInfo = 'Found camera: ${cameras[cameraIndex].name}';
      }
    } on PlatformException catch (e) {
      cameraInfo = 'Failed to get cameras: ${e.code}: ${e.message}';
    }

    if (mounted) {
      setState(() {
        _cameraIndex = cameraIndex;
        _cameras = cameras;
        _cameraInfo = cameraInfo;
      });
    }
  }

  Future<void> _initializeCamera() async {
    assert(!_initialized);

    if (_cameras.isEmpty) {
      return;
    }

    int cameraId = -1;
    try {
      final int cameraIndex = _cameraIndex % _cameras.length;
      final CameraDescription camera = _cameras[cameraIndex];

      cameraId = await CameraPlatform.instance.createCameraWithSettings(
        camera,
        _mediaSettings,
      );

      unawaited(_errorStreamSubscription?.cancel());
      _errorStreamSubscription = CameraPlatform.instance
          .onCameraError(cameraId)
          .listen(_onCameraError);

      unawaited(_cameraClosingStreamSubscription?.cancel());
      _cameraClosingStreamSubscription = CameraPlatform.instance
          .onCameraClosing(cameraId)
          .listen(_onCameraClosing);

      final Future<CameraInitializedEvent> initialized =
          CameraPlatform.instance.onCameraInitialized(cameraId).first;

      await CameraPlatform.instance.initializeCamera(
        cameraId,
      );

      final CameraInitializedEvent event = await initialized;
      _previewSize = Size(
        event.previewWidth,
        event.previewHeight,
      );

      if (mounted) {
        setState(() {
          _initialized = true;
          _cameraId = cameraId;
          _cameraIndex = cameraIndex;
          _cameraInfo = 'Capturing camera: ${camera.name}';
        });
      }
    } on CameraException catch (e) {
      try {
        if (cameraId >= 0) {
          await CameraPlatform.instance.dispose(cameraId);
        }
      } on CameraException catch (e) {
        debugPrint('Failed to dispose camera: ${e.code}: ${e.description}');
      }

      // Reset state.
      if (mounted) {
        setState(() {
          _initialized = false;
          _cameraId = -1;
          _cameraIndex = 0;
          _previewSize = null;
          _cameraInfo =
              'Failed to initialize camera: ${e.code}: ${e.description}';
        });
      }
    }
  }

  Future<void> _disposeCurrentCamera() async {
    if (_cameraId >= 0 && _initialized) {
      try {
        await CameraPlatform.instance.dispose(_cameraId);

        if (mounted) {
          setState(() {
            _initialized = false;
            _cameraId = -1;
            _previewSize = null;
          });
        }
      } on CameraException catch (e) {
        if (mounted) {
          setState(() {
            _cameraInfo =
                'Failed to dispose camera: ${e.code}: ${e.description}';
          });
        }
      }
    }
  }

  Widget _buildPreview() {
    return CameraPlatform.instance.buildPreview(_cameraId);
  }

  Future<void> _captureScreenshot() async {
    final image = await screenshotController.capture();
    if (image != null) {
      final directory = await Directory.systemTemp.createTemp();
      final path = '${directory.path}/screenshot.png';
      screenshotFile = File(path);
      await screenshotFile!.writeAsBytes(image);
      setState(() {});
    }
  }

  Future<void> _captureHeadshot() async {
    if (!_initialized || _cameraId < 0) return;
    try {
      final XFile file = await CameraPlatform.instance.takePicture(_cameraId);
      setState(() {
        headshotFile = file;
      });
    } catch (e) {
      print('Error capturing headshot: $e');
    }
  }

  void _startTimer() {
    if (!_isTimerRunning) {
      setState(() {
        _isTimerRunning = true;
      });
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _seconds++;
      });
    });
  }

  void _pauseTimer() {
    if (_timer != null) {
      _timer!.cancel();
      setState(() {
        _isTimerRunning = false;
      });
    }
  }

  void _resetTimer() {
    _pauseTimer();
    setState(() {
      _seconds = 0;
    });
  }

  String formatDuration(int totalSeconds) {
    final duration = Duration(seconds: totalSeconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;
    final seconds = duration.inSeconds % 60;

    return [hours, minutes, seconds]
        .map((seg) => seg.toString().padLeft(2, '0'))
        .join(':');
  }

  void _startCapture() {
    // _initializeCamera();
    if (!_isTimerRunning) {
      _startTimer();
      _captureHeadshot();
      _captureScreenshot();
    }
  }

  void _startCamera() {
    if (_initialized) {
      _disposeCurrentCamera();
    } else {
      _initializeCamera();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Timer App'),
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Align(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Screenshot(
                    controller: screenshotController,
                    child: Column(
                      children: [
                        Text(
                          formatDuration(_seconds),
                          style: const TextStyle(
                              fontSize: 26, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 20),
                        if (_initialized &&
                            _cameraId >= 0 &&
                            _previewSize != null)
                          Container(
                            constraints: const BoxConstraints(maxHeight: 200),
                            child: AspectRatio(
                              aspectRatio:
                                  _previewSize!.width / _previewSize!.height,
                              child: _buildPreview(),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  ElevatedButton(
                    onPressed: () {
                      _startCamera();
                    },
                    child: _initialized
                        ? const Text('Close Camera')
                        : const Text('Open Camera'),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _startCapture,
                    child: const Text('Start Timer and Capture'),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        height: 40,
                        width: 40,
                        child: FloatingActionButton(
                          shape: const CircleBorder(),
                          splashColor: Colors.white54,
                          onPressed:
                              _isTimerRunning ? _pauseTimer : _startTimer,
                          child: _isTimerRunning
                              ? const Icon(Icons.pause)
                              : const Icon(Icons.play_arrow),
                        ),
                      ),
                      const SizedBox(
                        width: 10,
                      ),
                      SizedBox(
                        height: 40,
                        width: 40,
                        child: FloatingActionButton(
                            shape: const CircleBorder(),
                            splashColor: Colors.white54,
                            onPressed: _resetTimer,
                            child: const Icon(Icons.replay)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (screenshotFile != null)
            Positioned(
              bottom: 20,
              right: 20,
              child: Container(
                color: Colors.white,
                child: Image.file(
                  screenshotFile!,
                  width: 250,
                  height: 250,
                  fit: BoxFit.cover,
                ),
              ),
            )
        ],
      ),
    );
  }

  void _onCameraError(CameraErrorEvent event) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: ${event.description}')),
      );

      // Dispose camera on camera error as it cannot be used anymore.
      _disposeCurrentCamera();
      _fetchCamera();
    }
  }

  void _onCameraClosing(CameraClosingEvent event) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Closing camera: ${event.cameraId}')),
      );
    }
  }
}
