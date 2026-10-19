# apple-bridge

Small, self-hosted tools that connect Apple devices (iPhone, iPad, Mac) with Windows and Linux PCs.
No cloud service, no account: everything runs on your own network.

## Tools

| Tool | What it does | Platforms |
|---|---|---|
| [iphone-clipboard](iphone-clipboard/) | Shared clipboard over Wi-Fi: copy text, images and files on one device, paste on the other | iPhone ⇄ Windows |

More tools will be added here.

## Layout

Each tool lives in its own folder with its own README:

```
apple-bridge/
├── README.md            this overview
└── iphone-clipboard/
    ├── README.md        setup guide (PC and iPhone)
    └── clip-sync.ps1    Windows script
```

## Security

The tools are meant for your local network. Don't expose their ports to the internet.
Secrets such as `key.txt` are generated on your machine and are never committed (see `.gitignore`).
