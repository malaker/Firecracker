@{
    ImageRepo      = 'malaker/nanoserver'
    DefaultFlavour = 'aspnet-x86'
    DefaultRuntime = 'docker'

    Docker = @{
        Version = '27.5.1'
        Url     = 'https://download.docker.com/win/static/stable/x86_64/docker-27.5.1.zip'
        Sha256  = 'a573be076030c8babe34ffcd89c7ad6e720cfb4f876a0f8412dba7ecdd368926'
    }

    Containerd = @{
        Version = '1.7.25'
        Url     = 'https://github.com/containerd/containerd/releases/download/v1.7.25/containerd-1.7.25-windows-amd64.tar.gz'
        Sha256  = 'ec819a29d81b52a1aa8ffd995751639de7102ac08d54a0248d1d1484809e0460'
    }

    Nerdctl = @{
        Version = '2.0.3'
        Url     = 'https://github.com/containerd/nerdctl/releases/download/v2.0.3/nerdctl-2.0.3-windows-amd64.tar.gz'
        Sha256  = 'c1b98fda05d00356a51923e5af427ddeb148c3540a711beb7a6a884a5f9fe75b'
    }
}
