#!/bin/sh
set -e

channel=$1

APPARMOR_URL="https://version.home-assistant.io/apparmor.txt"

# Make sure we can talk to the Docker daemon
echo "Waiting for Docker daemon..."
while ! docker version 2> /dev/null > /dev/null; do
	sleep 1
done

# 安裝 jq for JSON parsing (version.json 要用) 這裡安裝的話， HAOS 裡面就有 jq 可用了，有想要加的工具也可以在這裡加上去
echo "Installing jq..."
apk add --no-cache jq

# Install Supervisor, plug-ins and landing page
echo "Loading container images..."

# Make sure to order images by size (largest first)
# It seems docker load requires space during operation
# shellcheck disable=SC2045
for image in $(ls -S /build/images/*.tar); do
	docker load --input "${image}"
done

# Tag the Supervisor how the OS expects it to be tagged
supervisor=$(docker images --filter "label=io.hass.type=supervisor" --quiet)
arch=$(docker inspect --format '{{ index .Config.Labels "io.hass.arch" }}' "${supervisor}")
docker tag "${supervisor}" "ghcr.io/home-assistant/${arch}-hassio-supervisor:latest"


echo "打 tag..."

# 上面 docker load --input "${image}" 會讀取在 hassio.mk 指定抓的 image，也包含我們的 core，我們要把我們的 core tag 成官方的 core image 名稱，讓 Supervisor 可以順利讀取我們的 image
version_json="/build/version.json"
if [ -f "${version_json}" ]; then
    mycore_version=$(jq -r '.mycore // empty' "${version_json}")
    core_image_template=$(jq -r '.images.core // empty' "${version_json}")

    if [ -n "${mycore_version}" ] && [ -n "${core_image_template}" ]; then
        # 找到 hassio.mk 指定的 mycore image (togetherlearn images)
        mycore=$(docker images --filter "reference=togetherlearn/*" --quiet | head -n1)

        if [ -n "${mycore}" ]; then
            # Extract machine name from image tag
            # Example: togetherlearn/raspberrypi5-64-homeassistant:2025.10.4
            mycore_full=$(docker inspect --format '{{index .RepoTags 0}}' "${mycore}")
            mycore_name=$(echo "${mycore_full}" | cut -d':' -f1)
            machine=$(echo "${mycore_name}" | sed 's|^togetherlearn/||' | sed 's|-homeassistant$||')

            # Construct official core image name from template，替換 {machine} 為實際的 {machine}
            core_image=$(echo "${core_image_template}" | sed "s/{machine}/${machine}/")

            # Get the actual version from image label (io.hass.version) 我們打包的 image 裡面有這個 label 是繼承至 build base imgae 來的，Supervisor 會去檢查這個版本號
            actual_version=$(docker inspect --format '{{ index .Config.Labels "io.hass.version" }}' "${mycore}")

            # Tag mycore as official core
            docker tag "${mycore}" "${core_image}:latest"
            docker tag "${mycore}" "${core_image}:${mycore_version}"

            # Also tag with the actual version from image label if different
            if [ -n "${actual_version}" ] && [ "${actual_version}" != "${mycore_version}" ]; then
                docker tag "${mycore}" "${core_image}:${actual_version}"
                echo "也已打 Also tagged as ${core_image}:${actual_version} (from image label)"
            fi

            echo "已打 Tagged ${mycore_full} as ${core_image}:${mycore_version}"
        fi
    fi
fi

docker images



# Setup AppArmor
mkdir -p "/data/supervisor/apparmor"
wget -O "/data/supervisor/apparmor/hassio-supervisor" "${APPARMOR_URL}"

echo "{ \"channel\": \"${channel}\" }" > /data/supervisor/updater.json
