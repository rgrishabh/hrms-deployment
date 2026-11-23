# Brand files

Put logos and the favicon here. They are mounted read-only at `/brand` and served at `/brand/<file>`, so nothing is rebuilt. Reference them from `.brandenv`, for example `BRAND_LOGO_URL=/brand/logo.svg`.

Files in this folder are public on the installation's site, and this repository is public. Do not commit client logos here: copy them to the host, or keep them in the client's private repository.
