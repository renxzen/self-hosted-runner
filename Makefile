.PHONY: up down build

up:
	@docker compose up --build --force-recreate --detach
down:
	@docker compose down

build:
	@docker buildx build \
		--platform linux/amd64 \
		-t renxzen/github-actions:latest \
		--push ./build
