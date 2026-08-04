#!/bin/bash
mkdir code
cp -r ../src/* code/
cd code

docker buildx build --tag 1 --file ./Dockerfile .
docker tag nodeapp:1 us-central1-docker.pkg.dev/$1/nodeapp/nodeapp:1
docker push us-central1-docker.pkg.dev/$1/nodeapp/nodeapp:1