#!/usr/bin/env just --justfile

# 使用 Just: https://github.com/casey/just?tab=readme-ov-file#installation

set quiet

# 列出所有可用的命令
default:
  just --list

# 安装所有依赖项（包括 JS 和 Rust 工具）
install:
    bun install
    cargo install --locked cargo-shear cargo-sort cargo-upgrades cargo-edit cargo-hack

# dev 命令的别名
all: dev

# 运行开发环境：启动 relay 服务器、web 服务器，并发布 bbb 视频
dev:
    # 安装 JavaScript 依赖
    bun install

    # 构建 Rust 包，让 `cargo run` 有一个启动优势
    cargo build

    # 然后运行 relay，稍微领先启动
    # Web 服务器晚于 BBB 也没关系，因为支持自动重载
    bun run concurrently --kill-others --names srv,bbb,web --prefix-colors auto \
        "just relay" \
        "sleep 1 && just pub bbb http://localhost:4443/anon" \
        "sleep 2 && just web http://localhost:4443/anon"


# 运行本地 relay 服务器（无需身份验证）
relay *args:
    # 运行 relay 服务器，覆盖提供的配置文件
    TOKIO_CONSOLE_BIND=127.0.0.1:6680 cargo run --bin moq-relay -- dev/relay.toml {{args}}

# 运行 relay 服务器集群（包括根节点和叶节点）
cluster:
    # 安装 JavaScript 依赖
    bun install

    # 如果需要，生成认证令牌
    @just auth-token

    # 构建 Rust 包，让 `cargo run` 有启动优势
    cargo build --bin moq-relay

    # 然后运行一堆服务以确保它们都正常工作
    # 将 funny bunny 发布到根节点
    # 将 robot fanfic 发布到叶节点
    bun run concurrently --kill-others --names root,leaf,bbb,tos,web --prefix-colors auto \
        "just root" \
        "sleep 1 && just leaf" \
        "sleep 2 && just pub bbb http://localhost:4444/demo?jwt=$(cat dev/demo-cli.jwt)" \
        "sleep 3 && just pub tos http://localhost:4443/demo?jwt=$(cat dev/demo-cli.jwt)" \
        "sleep 4 && just web http://localhost:4443/demo?jwt=$(cat dev/demo-web.jwt)"

# 运行本地根服务器，接受来自叶节点的连接
root: auth-key
    # 使用特殊配置文件运行根服务器
    cargo run --bin moq-relay -- dev/root.toml

# 运行本地叶节点服务器，连接到根服务器
leaf: auth-token
    # 使用特殊配置文件运行叶服务器
    cargo run --bin moq-relay -- dev/leaf.toml

# 生成用于身份验证的随机密钥
# 默认使用 HMAC-SHA256，因此是对称的
# 如果有人想贡献，公钥/私钥对会更好
auth-key:
    @if [ ! -f "dev/root.jwk" ]; then \
        rm -f dev/*.jwt; \
        cargo run --bin moq-token -- --key "dev/root.jwk" generate; \
    fi

# 为本地开发生成身份验证令牌
# demo-web.jwt - 允许发布到 demo/me/* 并订阅 demo/*
# demo-cli.jwt - 允许发布到 demo/* 但不能订阅
# root.jwt - 允许发布和订阅所有路径
auth-token: auth-key
    @if [ ! -f "dev/demo-web.jwt" ]; then \
        cargo run --quiet --bin moq-token -- --key "dev/root.jwk" sign \
            --root "demo" \
            --subscribe "" \
            --publish "me" \
            > dev/demo-web.jwt ; \
    fi

    @if [ ! -f "dev/demo-cli.jwt" ]; then \
        cargo run --quiet --bin moq-token -- --key "dev/root.jwk" sign \
            --root "demo" \
            --publish "" \
            > dev/demo-cli.jwt ; \
    fi

    @if [ ! -f "dev/root.jwt" ]; then \
        cargo run --quiet --bin moq-token -- --key "dev/root.jwk" sign \
            --root "" \
            --subscribe "" \
            --publish "" \
            --cluster \
            > dev/root.jwt ; \
    fi

# 下载测试视频并转换为可流式传输的分段 MP4 格式
download name:
    @if [ ! -f "dev/{{name}}.mp4" ]; then \
        curl -fsSL $(just download-url {{name}}) -o "dev/{{name}}.mp4"; \
    fi

    @if [ ! -f "dev/{{name}}.fmp4" ]; then \
        ffmpeg -loglevel error -i "dev/{{name}}.mp4" \
            -c:v copy \
            -f mp4 -movflags cmaf+separate_moof+delay_moov+skip_trailer+frag_every_frame \
            "dev/{{name}}.fmp4"; \
    fi

# 返回测试视频的 URL
download-url name:
    @case {{name}} in \
        bbb) echo "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4" ;; \
        tos) echo "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4" ;; \
        av1) echo "http://download.opencontent.netflix.com.s3.amazonaws.com/AV1/Sparks/Sparks-5994fps-AV1-10bit-1920x1080-2194kbps.mp4" ;; \
        hevc) echo "https://test-videos.co.uk/vids/jellyfish/mp4/h265/1080/Jellyfish_1080_10s_30MB.mp4" ;; \
        *) echo "unknown" && exit 1 ;; \
    esac

# 将 h264 输入文件转换为 CMAF (fmp4) 格式并输出到 stdout
ffmpeg-cmaf input output='-' *args:
    ffmpeg -hide_banner -v quiet \
        -stream_loop -1 -re \
        -i "{{input}}" \
        -c copy \
        -f mp4 -movflags cmaf+separate_moof+delay_moov+skip_trailer+frag_every_frame {{args}} {{output}}

# 使用 ffmpeg 将视频发布到本地 relay 服务器
# 注意：`http` 表示执行不安全的证书验证
# 当准备使用真实证书时，将其切换为 `https`
pub name url="http://localhost:4443/anon" prefix="" *args:
    # 下载示例媒体
    just download "{{name}}"
    # 预构建二进制文件，避免在编译时排队媒体
    cargo build --bin hang
    # 使用 hang cli 发布媒体
    just ffmpeg-cmaf "dev/{{name}}.fmp4" |\
    cargo run --bin hang -- \
        publish --url "{{url}}" --name "{{prefix}}{{name}}" {{args}} fmp4

# 从视频文件生成并摄取 HLS 流
pub-hls name relay="http://localhost:4443/anon":
    #!/usr/bin/env bash
    set -euo pipefail

    just download "{{name}}"

    INPUT="dev/{{name}}.mp4"
    OUT_DIR="dev/{{name}}"

    rm -rf "$OUT_DIR"
    mkdir -p "$OUT_DIR"

    echo ">>> 生成 HLS 流到磁盘 (1280x720 + 256x144)..."

    # 在后台启动 ffmpeg 生成 HLS
    ffmpeg -hide_banner -loglevel warning -re -stream_loop -1 -i "$INPUT" \
        -filter_complex "\
        [0:v]split=2[v0][v1]; \
        [v0]scale=-2:720[v720]; \
        [v1]scale=-2:144[v144]" \
        -map "[v720]" -map "[v144]" -map 0:a:0 \
        -r 25 -preset veryfast -g 50 -keyint_min 50 -sc_threshold 0 \
        -c:v:0 libx264 -profile:v:0 high -level:v:0 4.1 -pix_fmt:v:0 yuv420p -tag:v:0 avc1 \
        -b:v:0 4M -maxrate:v:0 4.4M -bufsize:v:0 8M \
        -c:v:1 libx264 -profile:v:1 high -level:v:1 4.1 -pix_fmt:v:1 yuv420p -tag:v:1 avc1 \
        -b:v:1 300k -maxrate:v:1 330k -bufsize:v:1 600k \
        -c:a aac -b:a 128k \
        -f hls -hls_time 2 -hls_list_size 12 \
        -hls_flags independent_segments+delete_segments \
        -hls_segment_type fmp4 \
        -master_pl_name master.m3u8 \
        -var_stream_map "v:0,agroup:audio,name:720 v:1,agroup:audio,name:144 a:0,agroup:audio,name:audio" \
        -hls_segment_filename "$OUT_DIR/v%v/segment_%09d.m4s" \
        "$OUT_DIR/v%v/stream.m3u8" &


    FFMPEG_PID=$!

    # 等待主播放列表生成
    echo ">>> 等待 HLS 播放列表生成..."
    for i in {1..30}; do
        if [ -f "$OUT_DIR/master.m3u8" ]; then
            break
        fi
        sleep 0.5
    done

    if [ ! -f "$OUT_DIR/master.m3u8" ]; then
        kill $FFMPEG_PID 2>/dev/null || true
        echo "错误：master.m3u8 未能及时生成"
        exit 1
    fi

    echo ">>> 从磁盘开始 HLS 摄取: $OUT_DIR/master.m3u8"

    # 捕获信号以在退出时清理 ffmpeg
    cleanup() {
        echo "正在关闭..."
        kill $FFMPEG_PID 2>/dev/null || true
        exit 0
    }
    trap cleanup SIGINT SIGTERM

    # 运行 hang 从本地文件摄取
    cargo run --bin hang -- publish --url "{{relay}}" --name "{{name}}" hls --playlist "$OUT_DIR/master.m3u8"

# 使用 H.264 Annex B 格式将视频发布到本地 relay 服务器
pub-h264 name url="http://localhost:4443/anon" *args:
    # 下载示例媒体
    just download "{{name}}"

    # 预构建二进制文件，避免在编译时排队媒体
    cargo build --bin hang

    # 运行 ffmpeg 并将 H.264 Annex B 输出管道传输到 hang
    ffmpeg -hide_banner -v quiet \
        -stream_loop -1 -re \
        -i "dev/{{name}}.fmp4" \
        -c:v copy -an \
        -bsf:v h264_mp4toannexb \
        -f h264 \
        - | cargo run --bin hang -- publish --url "{{url}}" --name "{{name}}" --format annex-b {{args}}

# 使用 gstreamer 发布/订阅 - 参见 https://github.com/moq-dev/gstreamer
pub-gst name url='http://localhost:4443/anon':
    @echo "GStreamer 插件已移至: https://github.com/moq-dev/gstreamer"
    @echo "请直接安装并使用 hang-gst 以使用 GStreamer 功能"

# 使用 gstreamer 订阅视频 - 参见 https://github.com/moq-dev/gstreamer
sub name url='http://localhost:4443/anon':
    @echo "GStreamer 插件已移至: https://github.com/moq-dev/gstreamer"
    @echo "请直接安装并使用 hang-gst 以使用 GStreamer 功能"

# 直接从 hang 使用 ffmpeg 发布视频到本地服务器
# 若要同时通过 iroh 提供服务，请在最后传递 --iroh-enabled 参数
serve name *args:
    # 下载示例媒体
    just download "{{name}}"

    # 预构建二进制文件，避免在编译时排队媒体
    cargo build --bin hang

    # 运行 ffmpeg 并将输出管道传输到 hang
    just ffmpeg-cmaf "dev/{{name}}.fmp4" |\
    cargo run --bin hang -- \
        {{args}} serve --listen "[::]:4443" --tls-generate "localhost" \
        --name "{{name}}" fmp4

# 运行 web 服务器
web url='http://localhost:4443/anon':
    cd js/hang-demo && VITE_RELAY_URL="{{url}}" bun run dev

# 发布时钟广播
# `action` 可以是 `publish` 或 `subscribe`
clock action url="http://localhost:4443/anon" *args:
    @if [ "{{action}}" != "publish" ] && [ "{{action}}" != "subscribe" ]; then \
        echo "错误：action 必须是 'publish' 或 'subscribe'，得到 '{{action}}'" >&2; \
        exit 1; \
    fi

    cargo run --bin moq-clock -- --url "{{url}}" --broadcast "clock" {{args}} {{action}}

# 运行 CI 检查
check:
    #!/usr/bin/env bash
    set -euo pipefail

    # 运行 JavaScript 检查
    bun install --frozen-lockfile
    if tty -s; then
        bun run --filter='*' --elide-lines=0 check
    else
        bun run --filter='*' check
    fi
    bun biome check

    # 运行（较慢的）Rust 检查
    cargo check --all-targets --all-features
    cargo clippy --all-targets --all-features -- -D warnings
    cargo fmt --all --check

    # 检查文档警告（仅工作区 crate，不包括依赖项）
    RUSTDOCFLAGS="-D warnings" cargo doc --no-deps --workspace

    # 需要: cargo install cargo-shear
    cargo shear

    # 需要: cargo install cargo-sort
    cargo sort --workspace --check

    # 仅当安装了 tofu 时才运行 tofu 检查
    if command -v tofu &> /dev/null; then (cd cdn && just check); fi

    # 仅当安装了 nix 时才运行 nix 检查
    if command -v nix &> /dev/null; then nix flake check; fi

# 运行全面的 CI 检查，包括所有功能组合（需要 cargo-hack）
check-all:
    #!/usr/bin/env bash
    set -euo pipefail

    # 首先运行标准检查
    just check

    # 检查 hang crate 的所有功能组合
    # 需要: cargo install cargo-hack
    echo "正在检查 hang 的所有功能组合..."
    cargo hack check --package hang --each-feature --no-dev-deps

# 运行单元测试
test:
    #!/usr/bin/env bash
    set -euo pipefail

    # 运行 JavaScript 测试
    bun install --frozen-lockfile
    if tty -s; then
        bun run --filter='*' --elide-lines=0 test
    else
        bun run --filter='*' test
    fi

    cargo test --all-targets --all-features

# 运行全面测试，包括所有功能组合（需要 cargo-hack）
test-all:
    #!/usr/bin/env bash
    set -euo pipefail

    # 首先运行标准测试
    just test

    # 测试 hang crate 的所有功能组合
    # 需要: cargo install cargo-hack
    echo "正在测试 hang 的所有功能组合..."
    cargo hack test --package hang --each-feature

# 自动修复一些问题
fix:
    # 修复 JavaScript 依赖
    bun install
    bun biome check --write

    # 修复 Rust 问题
    cargo clippy --fix --allow-staged --allow-dirty --all-targets --all-features
    cargo fmt --all

    # 需要: cargo install cargo-shear
    cargo shear --fix

    # 需要: cargo install cargo-sort
    cargo sort --workspace

    if command -v tofu &> /dev/null; then (cd cdn && just fix); fi

# 升级任何工具
update:
    bun update
    bun outdated

    # 更新任何补丁版本
    cargo update

    # 需要: cargo install cargo-upgrades cargo-edit
    cargo upgrade --incompatible

    # 更新 Nix flake
    nix flake update

# 构建包
build:
    bun run --filter='*' build
    cargo build

# 生成并提供 HLS 流以测试 pub-hls
serve-hls name port="8000":
    #!/usr/bin/env bash
    set -euo pipefail

    just download "{{name}}"

    INPUT="dev/{{name}}.mp4"
    OUT_DIR="dev/{{name}}"

    rm -rf "$OUT_DIR"
    mkdir -p "$OUT_DIR"

    echo ">>> 开始生成 HLS 流..."
    echo ">>> 主播放列表: http://localhost:{{port}}/master.m3u8"

    cleanup() {
        echo "正在关闭..."
        kill $(jobs -p) 2>/dev/null || true
        exit 0
    }
    trap cleanup SIGINT SIGTERM

    ffmpeg -loglevel warning -re -stream_loop -1 -i "$INPUT" \
        -map 0:v:0 -map 0:v:0 -map 0:a:0 \
        -r 25 -preset veryfast -g 50 -keyint_min 50 -sc_threshold 0 \
        -c:v:0 libx264 -profile:v:0 high -level:v:0 4.1 -pix_fmt:v:0 yuv420p -tag:v:0 avc1 -bsf:v:0 dump_extra -b:v:0 4M -vf:0 "scale=1920:-2" \
        -c:v:1 libx264 -profile:v:1 high -level:v:1 4.1 -pix_fmt:v:1 yuv420p -tag:v:1 avc1 -bsf:v:1 dump_extra -b:v:1 300k -vf:1 "scale=256:-2" \
        -c:a aac -b:a 128k \
        -f hls \
        -hls_time 2 -hls_list_size 12 \
        -hls_flags independent_segments+delete_segments \
        -hls_segment_type fmp4 \
        -master_pl_name master.m3u8 \
        -var_stream_map "v:0,agroup:audio v:1,agroup:audio a:0,agroup:audio" \
        -hls_segment_filename "$OUT_DIR/v%v/segment_%09d.m4s" \
        "$OUT_DIR/v%v/stream.m3u8" &

    sleep 2
    echo ">>> HTTP 服务器: http://localhost:{{port}}/"
    cd "$OUT_DIR" && python3 -m http.server {{port}}

# 连接 tokio-console 到 relay 服务器（端口 6680）
relay-console:
    tokio-console http://127.0.0.1:6680

# 连接 tokio-console 到发布者（端口 6681）
pub-console:
    tokio-console http://127.0.0.1:6681

# 在本地提供文档服务
doc:
    cd doc && bun run dev

# 限制 UDP 流量以进行测试（仅限 macOS，需要 sudo）
throttle:
    dev/throttle
