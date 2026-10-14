docker compose --profile admin build manager # Build the repo-manager container

docker compose --profile admin run --rm manager keygen # Generate signing keys
docker compose --profile admin run --rm manager build hello-custom # Build the hello-custom package
docker compose --profile admin run --rm manager index # Publish the repository index, it is automatically built when packages are built

docker compose up -d web # Start the web server

docker compose --profile admin run --rm tester # Test the repo