FROM python:3.12-slim

WORKDIR /satellite

COPY satellites/python/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY satellites/python/chronicle_satellite.py .
COPY satellites/python/chronicle_satellite ./chronicle_satellite
COPY config/certs ./config/certs

EXPOSE 8090

HEALTHCHECK --interval=10s --timeout=3s --retries=3 CMD ["python", "-c", "import os,urllib.request; enabled=os.environ.get('SATELLITE_OBSERVABILITY_ENABLED','true').lower() not in ('0','false','no','off'); port=os.environ.get('SATELLITE_OBSERVABILITY_PORT','8090'); (not enabled) or urllib.request.urlopen('http://127.0.0.1:%s/readyz' % port, timeout=2).read()"]

CMD ["python", "-u", "chronicle_satellite.py"]
