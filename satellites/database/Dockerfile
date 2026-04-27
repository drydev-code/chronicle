FROM python:3.12-slim

WORKDIR /satellite

COPY satellites/database/requirements.txt ./app-requirements.txt
RUN pip install --no-cache-dir -r app-requirements.txt

COPY satellites/shared/python ./shared/python
COPY satellites/database/main.py ./app/main.py
COPY config/certs ./config/certs

ENV PYTHONPATH=/satellite/shared/python

EXPOSE 8090

HEALTHCHECK --interval=10s --timeout=3s --retries=3 CMD ["python", "-c", "import os,urllib.request; enabled=os.environ.get('SATELLITE_OBSERVABILITY_ENABLED','true').lower() not in ('0','false','no','off'); port=os.environ.get('SATELLITE_OBSERVABILITY_PORT','8090'); (not enabled) or urllib.request.urlopen('http://127.0.0.1:%s/readyz' % port, timeout=2).read()"]

CMD ["python", "-u", "/satellite/app/main.py"]
