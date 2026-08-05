#!/bin/bash
mkdir code
cp -r ../src/* code/
cd code

docker buildx build --tag nodeapp --file ./Dockerfile .
docker tag nodeapp:latest us-central1-docker.pkg.dev/$1/nodeapp/nodeapp:latest
docker push us-central1-docker.pkg.dev/$1/nodeapp/nodeapp:latest