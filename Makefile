VERSION=1.0.2
.PHONY: up down build

up:
	@docker compose up --build --force-recreate --detach
down:
	@docker compose down

publish:
	@docker buildx build \
		--platform linux/amd64 \
		-t renxzen/github-actions:v$(VERSION) \
		--push ./build
