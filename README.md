# Camera to cloud recording

This project receives an RTMP stream from a camera, exposes it for viewing
through RTSP or HLS, records it as 10-minute MP4 segments, and moves completed
segments to an S3-compatible bucket.

```text
Camera
  └─ RTMP publish ──> MediaMTX (Docker)
                         ├─ RTSP/HLS viewing
                         └─ MP4 segments in ./recordings/cam1
                               └─ rclone move ──> S3-compatible storage
```

## What is included

- `docker-compose.yml` runs MediaMTX.
- `mediamtx.yml` enables RTMP ingest, RTSP/HLS playback, and recording.
- `push_to_S3.sh` moves completed recordings to cloud storage.
- `recordings/` is the local recording volume and should remain untracked.
- `upload.log` contains local upload diagnostics and should remain untracked.

## Prerequisites

Install the following on the machine that will run the recorder:

1. Docker Desktop (or Docker Engine with the Compose plugin).
2. `rclone`.
3. A camera that supports RTMP publishing.
4. An S3-compatible bucket and a restricted access key.
5. Network access from the camera to the recorder's TCP port `1935`.

The examples use macOS paths and `Asia/Kolkata`; change these for another host
or timezone.

## 1. Prepare the project

Clone the repository and enter it:

```bash
git clone <YOUR_REPOSITORY_URL> cam
cd cam
mkdir -p recordings/cam1
chmod +x push_to_S3.sh
```

Do not copy existing recordings or `upload.log` into the repository.

## 2. Configure MediaMTX

Open `mediamtx.yml` and configure:

- `rtmp: yes` and `rtmpAddress: :1935` for camera ingest.
- `rtsp: yes` and `hls: yes` for playback.
- `paths.cam1` as the stream path.
- `record: yes` to enable recording.
- `recordPath` to write under `/recordings/cam1`.
- `recordSegmentDuration: 10m` to create 10-minute segments.

The current file contains a publish credential:

```yaml
- user: camera
  pass: <hard-to-guess-password>
```

Replace the current value with a strong, unique password before publishing the
repository. Configure the same username and password in the camera. Do not
commit real credentials, private keys, or cloud configuration files.

The `any` user is restricted to localhost and Docker's private network ranges
for read/playback/API access. Keep it restricted unless you have a specific
reason to expose playback outside the host.

## 3. Start MediaMTX

Start the service from the project directory:

```bash
docker compose up -d
docker compose ps
docker compose logs -f mediamtx
```

The Compose file publishes:

| Port | Protocol | Purpose |
|---:|---|---|
| `1935` | RTMP | Camera publishes the stream |
| `8554` | RTSP | VLC or other RTSP clients |
| `8888` | HLS over HTTP | Browser-compatible playback |

The recording directory is mounted into the container, so files persist on
the host in `recordings/cam1`.

## 4. Configure the camera

In the camera's network/streaming settings, select RTMP and enter:

```text
RTMP server/URL: rtmp://<RECORDER_IP>:1935
Stream key/path: cam1
Username: camera
Password: <THE_PASSWORD_FROM_MEDIAMTX>
```

Some cameras require one combined URL instead:

```text
rtmp://camera:<URL_ENCODED_PASSWORD>@<RECORDER_IP>:1935/cam1
```

Use the camera manufacturer's exact field format. The recorder's IP must be
reachable from the camera, and TCP port `1935` must be allowed by the host
firewall. If the camera is on another network, use a VPN or a properly
secured private network; do not expose an unauthenticated RTMP port directly
to the public internet.

After starting the camera, verify that MediaMTX reports a publisher:

```bash
docker compose logs -f mediamtx
find recordings/cam1 -type f -name '*.mp4' -print
```

## 5. View the live stream

Replace `<RECORDER_IP>` with the recorder's LAN IP.

### RTSP (VLC)

```text
rtsp://<RECORDER_IP>:8554/cam1
```

Open this URL in VLC or another RTSP client.

### HLS (browser/player)

```text
http://<RECORDER_IP>:8888/cam1/index.m3u8
```

HLS is a playlist URL, not a standalone HTML page. Use an HLS-capable player
or a small web page using `hls.js`. Do not expose port `8888` publicly without
adding appropriate access control.

## 6. Configure cloud storage with rclone

Create a private S3 bucket and a dedicated IAM/service account scoped to that
bucket and the `cam1/` prefix. For this `rclone move` workflow, grant bucket
listing plus object `GetObject`, `PutObject`, and `DeleteObject` permissions.
`GetObject` is needed for metadata/head checks by rclone; `DeleteObject` is
used only after an upload succeeds. Do not grant account-wide or bucket
administration permissions.

Configure an rclone remote named `s3cam`:

```bash
rclone config
rclone listremotes
```

For AWS S3, choose the `s3` provider and enter the region, access key, secret
key, and endpoint when prompted. For another S3-compatible provider, enter its
endpoint and provider-specific region/settings. The destination used by the
script is:

```text
s3cam:cam1-recording/cam1
```

Test access before enabling automatic deletion of local files:

```bash
rclone lsd s3cam:
rclone lsd s3cam:cam1-recording
rclone copy ./recordings/cam1 s3cam:cam1-recording/cam1 --include '*.mp4' --dry-run
```

The rclone credentials are normally stored outside the repository in:

```text
~/.config/rclone/rclone.conf
```

That file must never be committed or pasted into an issue, pull request, or
chat.

The repository's upload script currently expects the rclone remote name
`s3cam`, bucket `cam1-recording`, and destination prefix `cam1`. If you use
different names, update `DEST` in `push_to_S3.sh` to match before running it.

## 7. Test the upload script

The script:

- reads `recordings/cam1`;
- ignores files that are not `.mp4`;
- waits until a file is at least 15 minutes old, preventing upload of the
  active 10-minute segment;
- allows only one upload process at a time using `/tmp/cam-upload.lock`;
- uses two transfers in parallel;
- writes diagnostics to `upload.log`; and
- moves successful uploads to `s3cam:cam1-recording/cam1`, removing the local
  copy after success.

Run it manually:

```bash
./push_to_S3.sh
tail -f upload.log
rclone ls s3cam:cam1-recording/cam1
```

The source and destination are currently hard-coded for `$HOME/cam`. If the
project is installed elsewhere, update `SRC` and `LOG` in
`push_to_S3.sh` before scheduling it.

## 8. Schedule uploads

On macOS or Linux, run the script periodically after verifying a manual run.
For example, edit the user's crontab:

```bash
crontab -e
```

Run every five minutes:

```cron
*/5 * * * * /Users/<USER>/cam/push_to_S3.sh
```

Use the absolute path to the script. The script's age check and lock prevent
the active segment and overlapping runs from being uploaded. Check
`upload.log` regularly and configure host-level log rotation/backups if
needed.

## 9. Stop, restart, and troubleshoot

```bash
docker compose restart
docker compose logs --tail=200 mediamtx
docker compose down
docker compose up -d
```

Common checks:

```bash
# Is the container running?
docker compose ps

# Are files being recorded?
find recordings/cam1 -type f -name '*.mp4' -mmin -30 -print

# Can the cloud remote be reached?
rclone lsd s3cam:

# Is the upload lock stale?
ls -ld /tmp/cam-upload.lock
```

If the camera cannot publish, verify the recorder IP, TCP `1935`, the `cam1`
path, and the publish credentials. If recording works but cloud upload fails,
check `upload.log`, the rclone remote name, bucket name, endpoint/region, and
the IAM permissions. A failed `rclone move` leaves the local files in place;
do not delete them until the cloud copy is verified.

## Security and GitHub checklist

Before the first push:

1. Replace the sample MediaMTX password and rotate it if this directory has
   ever been shared.
2. Confirm that AWS/S3 access keys are not in the repository, shell history,
   CI logs, or screenshots.
3. Keep `~/.config/rclone/rclone.conf` outside the repository.
4. Keep recordings, `.DS_Store` files, upload logs, and lock files untracked.
5. Use a private bucket and least-privilege credentials.
6. Restrict RTMP, RTSP, and HLS ports to the required network or VPN.
7. Enable bucket encryption, versioning, and a retention/lifecycle policy as
   appropriate for the footage.
8. Revoke and replace any credential that was committed, even if the commit
   was later deleted; Git history and forks may retain it.

This workspace currently has no `.git` directory, so initialize or clone the
GitHub repository before running Git checks. Then run these checks before
committing:

```bash
git status --short
git diff --check
git grep -n -I -E 'AKIA[0-9A-Z]{16}|aws_secret_access_key|secret_access_key|BEGIN (RSA|OPENSSH|EC) PRIVATE KEY'
```

The last command should return no cloud credentials or private keys. Review
`mediamtx.yml` separately to ensure the publish password is a safe value.
