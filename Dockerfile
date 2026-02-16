FROM hearmeman/comfyui-qwen-template:v5

SHELL ["/bin/bash", "-lc"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl rsync nano ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install -U pip setuptools wheel \
 && python3 -m pip install jupyterlab

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8188 8888
ENTRYPOINT ["/start.sh"]
