VERSION=1.1.1
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
