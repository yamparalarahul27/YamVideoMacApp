import functools, http.server, os, pathlib, subprocess, sys, tempfile, threading, time
with tempfile.TemporaryDirectory(prefix='yamvideo-download-fixture-') as directory:
    fixture = pathlib.Path(directory) / 'clip.mp4'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=400', '-t', '3', '-c:v', 'libx264', '-preset', 'ultrafast', '-c:a', 'aac', '-movflags', '+faststart', str(fixture)], check=True)
    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args): pass
        def copyfile(self, source, output):
            try:
                while data := source.read(32768):
                    output.write(data); output.flush(); time.sleep(.04)
            except (BrokenPipeError, ConnectionResetError): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(Handler, directory=directory))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = os.environ | {'YAMVIDEO_TEST_DOWNLOAD_URL': f'http://127.0.0.1:{server.server_port}/clip.mp4'}
    try: subprocess.run([sys.argv[1]], env=env, check=True, timeout=180)
    finally: server.shutdown()
