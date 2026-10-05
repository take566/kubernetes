# Inactive Argo CD Applications

Manifests here are kept for reference but are NOT synced: root-application only
reads `argocd/apps`. Moving a file out of `argocd/apps` makes root-application
prune the Application object; drop its `resources-finalizer.argocd.argoproj.io`
first if it still owns live resources, or the deletion cascades (#71).
See `argocd/apps/DEPRECATED.md` for why each one is here.
