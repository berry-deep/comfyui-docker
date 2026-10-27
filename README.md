# ComfyUI Docker Image（Clore.ai 部署）

把 [ComfyUI](https://github.com/Comfy-Org/ComfyUI) + [ComfyUI-Manager](https://github.com/Comfy-Org/ComfyUI-Manager)
打包成一个可直接下单租用 GPU 的镜像，构建产物推送到 **GHCR**（GitHub Container Registry）。

* 基础镜像：`cloreai/jupyter:ubuntu24.04-v2`（自带 Jupyter + SSH 的后台服务）
* 预装：PyTorch 2.9.1 + CUDA 12.8（cu128）运行时
* 不覆盖 `ENTRYPOINT` / `CMD`，保留基础镜像原本的服务与 SSH 启动逻辑

---

## 1. 目录结构

```
D:\comfu
├── Dockerfile                       # 镜像定义（分层：系统依赖 → venv+PyTorch → ComfyUI → Manager → 冒烟测试）
├── .dockerignore                    # 保持构建上下文精简
├── .gitignore
├── README.md
└── .github
    └── workflows
        └── build.yml                # GitHub Actions：构建 + 推送到 GHCR
```

> 本项目所有文件都在 `D:\comfu`，构建过程不写入 C 盘（见 [§6](#6-磁盘占用说明c-盘)）。

---

## 2. Dockerfile 分层设计

| 层 | 内容 | 说明 |
|---|---|---|
| 1 | `apt-get install git python3-venv python3-dev ffmpeg libgl1 libglib2.0-0 build-essential` | 同一层内 `rm -rf /var/lib/apt/lists/*`，不留 apt 缓存 |
| 2 | `/opt/venv` 虚拟环境 + `torch / torchvision / torchaudio` | **独立成层**：命中缓存时无需重装；本层体积可控（< 10 GB） |
| 3 | ComfyUI 克隆 + `pip install -r requirements.txt` | 支持 `COMFYUI_REF` = 分支 / Tag / Commit SHA |
| 4 | ComfyUI-Manager 克隆 + 安装其 `requirements.txt` | 位于 `/opt/ComfyUI/custom_nodes/ComfyUI-Manager` |
| 5 | 冒烟测试 | 仅校验包导入与版本，构建机无 GPU，不调用 `.cuda()` |

### 构建参数（`--build-arg`）

| 参数 | 默认值 | 说明 |
|---|---|---|
| `COMFYUI_REF` | `master` | ComfyUI 的分支、Tag 或 Commit SHA |
| `PYTORCH_VERSION` | `2.9.1` | PyTorch 版本（cu128） |
| `TORCHVISION_VERSION` | `0.24.1` | 必须与 PyTorch 版本配套 |
| `TORCHAUDIO_VERSION` | `2.9.1` | 必须与 PyTorch 版本配套 |
| `CUDA_VERSION` | `cu128` | PyTorch wheel 索引目录 |
| `PYTHON_VERSION` | `3.12` | 虚拟环境解释器版本（Ubuntu 24.04 自带 3.12） |

### 两个容易踩坑的设计点

1. **torch 不会被 requirements.txt 偷偷换掉**
   ComfyUI 的 `requirements.txt` 里写的是无版本号的 `torch` / `torchvision`。第 2 层会生成
   `/opt/pip-constraints.txt`，第 3、4 层安装时用 `-c /opt/pip-constraints.txt` 锁定，
   避免 pip 从 PyPI 拉一个 CUDA 版本不同的 torch 覆盖掉 cu128 构建。
2. **不改 `PATH`**
   基础镜像的启动脚本可能依赖它自己的解释器，因此没有设置 `ENV PATH`。
   调用 Python 时一律使用绝对路径 `/opt/venv/bin/python`。

---

## 3. 本地构建（可选）

> 本机需要 Docker Desktop / Docker Engine + Buildx。

```bash
cd /d/comfu

docker buildx build \
  --platform linux/amd64 \
  --build-arg COMFYUI_REF=master \
  --build-arg PYTORCH_VERSION=2.9.1 \
  -t comfyui:local \
  --load .
```

本地构建想完全不占 C 盘，把构建缓存也放到 D 盘：

```bash
# Docker Desktop → Settings → Resources → Disk image location 改成 D:\
# 同时把 CLI 配置也搬到 D 盘
setx DOCKER_CONFIG D:\comfu\.docker

docker buildx build \
  --platform linux/amd64 \
  --cache-to type=local,dest=D:\comfu\.buildcache \
  -t comfyui:local --load .
```

---

## 4. GitHub Actions 自动构建

`.github/workflows/build.yml` 已配置完毕，推送后自动运行：

* **触发**：`main` 分支 `push`；或 `workflow_dispatch` 手动触发
* **权限**：`contents: read` + `packages: write`
* **清理磁盘**：使用 `jlumbroso/free-disk-space@v1.3.2`
  移除 Android / .NET / Haskell / 大体积包；**保留** Docker 镜像与 tool-cache（构建缓存需要），保留 swap（避免构建期 OOM）
* **平台**：固定 `linux/amd64`
* **缓存**：registry 模式 `type=registry,ref=ghcr.io/<小写仓库名>:buildcache,mode=max`
* **推送标签**：
  * `latest`（仅默认分支构建时）
  * `YYYYMMDD`（构建日期，如 `20261027`）
  * 短 `sha`（如 `a1b2c3d`）

### 手动触发并指定版本

GitHub 仓库 → **Actions** → **Build ComfyUI Image** → **Run workflow**，
可填：

* `comfyui_ref`：`master` / `v0.3.x` / 40 位 Commit SHA
* `pytorch_version`：如 `2.8.0`（需同时改 `TORCHVISION_VERSION` / `TORCHAUDIO_VERSION`，见 Dockerfile ARG）

### 认证说明

镜像用内置的 `GITHUB_TOKEN` 登录 `ghcr.io`（`packages: write` 权限），**无需配置任何 secret**。
镜像名中的仓库路径会被强制转成小写（GHCR 的硬性要求）。

---

## 5. 把 GHCR 镜像设为 Public

私有包在 Clore.ai 侧无法匿名拉取，必须先公开：

1. 打开仓库 → 右侧栏 **Packages**
2. 点击对应的包（名字与仓库同名），进入 **Package settings**
3. 找到 **Change visibility** → 选择 **Public** → 确认
   （首次修改需要确认密码；组织名下可能需要 Organization Owner 权限）
4. 验证匿名可拉取：

   ```bash
   docker pull ghcr.io/<owner>/<repo>:latest
   ```

5. 之后在 Clore.ai 上单时直接填这个地址即可，无需再配置 registry 凭证。

---

## 6. Clore.ai 下单配置

### 6.1 镜像地址

在实例下单页面的 **Image / Container Image** 处选择 **Custom**，填：

```
ghcr.io/<owner>/<repo>:<tag>
```

例如：

```
ghcr.io/myuser/comfyui-docker:latest
ghcr.io/myuser/comfyui-docker:20261027
ghcr.io/myuser/comfyui-docker:a1b2c3d
```

> 必须是 Public 包，或在平台侧提供 GHCR 的拉取凭证，否则拉取会 401。

### 6.2 端口映射

| 容器端口 | 协议 | 用途 |
|---|---|---|
| `8188` | TCP | **ComfyUI WebUI**（必须映射，否则打不开界面） |
| `22` | TCP | SSH 登录（基础镜像自带） |
| `8888` | TCP | Jupyter Lab（基础镜像自带，可选） |

> Clore.ai 面板通常会给出一个外部端口，外部端口与容器端口的映射关系以平台实际分配为准；
> 容器内始终使用 `8188`。

### 6.3 启动命令（一行）

```
cd /opt/ComfyUI && /opt/venv/bin/python main.py --listen 0.0.0.0 --port 8188
```

要点说明：

* `--listen 0.0.0.0` **必须加**，否则只监听 `127.0.0.1`，平台外部访问不到；
* `--port 8188` 与端口映射保持一致；
* 用 `/opt/venv/bin/python` 而不是裸 `python`，确保走的是装了 torch 的虚拟环境。

### 6.4 存储挂载（强烈建议）

镜像本身不含模型，挂载持久化目录，实例销毁后模型不丢：

| 容器路径 | 内容 |
|---|---|
| `/opt/ComfyUI/models` | Checkpoint / VAE / LoRA / ControlNet 等 |
| `/opt/ComfyUI/input` | 输入图片 |
| `/opt/ComfyUI/output` | 生成结果 |
| `/root/.cache/huggingface` | HF 下载缓存 |

### 6.5 GPU 与驱动

* 实例请选择 **NVIDIA GPU**（显存 ≥ 8 GB；跑 SDXL / Flux 建议 16 GB 以上）。
* 宿主机 NVIDIA 驱动需支持 CUDA 12.8（建议 R570 及以上）。
  若平台驱动较旧，可用 `--build-arg CUDA_VERSION=cu126` 并换用对应 torch 版本重新构建。
* 容器内 PyTorch 使用 `cu128` wheel，运行时由 pip 的 `nvidia-*-cu12` 系列包提供 CUDA 库，无需在镜像内安装 CUDA Toolkit。

---

## 7. 常见运维

**更新 ComfyUI 到最新版**

```bash
# 在实例内 SSH 执行
cd /opt/ComfyUI && git pull && /opt/venv/bin/pip install --no-cache-dir -c /opt/pip-constraints.txt -r requirements.txt
```

或用新的 `COMFYUI_REF` 重新走一次 CI 构建，推送新的日期 / sha 标签后在 Clore.ai 换镜像标签。

**验证镜像里 torch 是对的**

```bash
/opt/venv/bin/python -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())"
```

**安装自定义节点**

```bash
git clone <repo> /opt/ComfyUI/custom_nodes/<name>
/opt/venv/bin/pip install --no-cache-dir -c /opt/pip-constraints.txt -r /opt/ComfyUI/custom_nodes/<name>/requirements.txt
```

也可以直接在 ComfyUI-Manager 界面里安装。

**镜像体积**

torch cu128 全家桶约 3 GB + NVIDIA CUDA 运行库约 3 GB + ComfyUI 与其依赖约 2 GB，
成品镜像预计 **10 GB 上下**；`latest` 与 `buildcache` 标签会占用 GHCR 配额，注意定期清理旧标签。

---

## 8. 磁盘占用说明（C 盘）

本项目**全部文件位于 `D:\comfu`**，构建过程不产生 C 盘占用：

* 项目源码、构建脚本：`D:\comfu`
* 本地构建缓存：显式指定 `--cache-to type=local,dest=D:\comfu\.buildcache`
* Docker CLI 配置：`setx DOCKER_CONFIG D:\comfu\.docker`
* Docker Desktop 的镜像/容器层默认仍落在 C 盘（`C:\Users\<你>\AppData\Local\Docker`），
  需要彻底腾出 C 盘时，在 **Docker Desktop → Settings → Resources → Disk image location** 改为 `D:\`，再 Apply & Restart。
* GitHub Actions 的构建与缓存全部发生在 GitHub Runner 的临时磁盘上，与本机无关。

---

## 9. 参考

* ComfyUI：<https://github.com/Comfy-Org/ComfyUI>
* ComfyUI-Manager：<https://github.com/Comfy-Org/ComfyUI-Manager>
* PyTorch cu128 wheel 索引：<https://download.pytorch.org/whl/cu128>
* GHCR 文档：<https://docs.github.com/packages/working-with-a-github-packages-registry/working-with-the-container-registry>
