# frozen_string_literal: true

module Chatly
  module Resources
    # Brands -- a sub-tenant's name, logo and colour inside one workspace.
    #
    # `client.brands`
    #
    # Open to a key so a platform can brand the widgets it provisions
    # instead of asking each customer to click through a form. Nothing here
    # records who changed it.
    class Brands < Base
      PATH = "/v1/brands"

      # Every brand, with usage counts. A bare Array, and the handler reads
      # no query parameters at all.
      #
      # A list row carries a `usage` object (`channels`, `conversations`,
      # `triggers`, `workflows`, always all four) that the create, update and
      # delete responses do NOT -- so the row here and the single brand
      # elsewhere are different shapes. The counts are what tell you whether
      # {#delete} will be refused.
      def list(query = {})
        http_get(PATH, query)
      end

      # Create a brand. Answers 201.
      #
      #   client.brands.create(name: "Acme Support", slug: "acme",
      #                        primaryColor: "#2b6cb0", supportEmail: "help@acme.test")
      #
      # `name:` and `slug:` are required; the slug is lowercase, digits and
      # hyphens.
      #
      # `domain:` and `replyDomain:` are two different things -- the help
      # centre's hostname and the outbound-mail hostname -- and it is worth
      # checking which one you meant. `logoUrl`, `primaryColor`,
      # `supportEmail`, `replyDomain` and `icons` are FLAT in the request
      # although they are stored inside a `branding` object, which never
      # appears under that name on the wire; the response flattens them back,
      # always present and nullable rather than absent.
      #
      # `isDefault: true` DEMOTES every other brand -- a write whose side
      # effect lands on rows you did not name.
      def create(attributes = {}, **kwargs)
        http_post(PATH, merge_body(attributes, kwargs))
      end

      # Update a brand. Every create field, optional, `slug` included.
      #
      # `icons:` MERGES per icon while everything else replaces, so sending
      # one icon leaves the other overrides alone -- and nothing clears an
      # icon except a new value for it. The body is not strict, so an
      # unrecognised field is dropped and you get a 200 that changed nothing.
      #
      # Validate the id yourself: unlike {#delete}, this route does not parse
      # it, so a malformed id reaches Postgres and comes back as a 500 rather
      # than a 400.
      def update(id, attributes = {}, **kwargs)
        http_patch(expand("#{PATH}/{id}", id), merge_body(attributes, kwargs))
      end

      # Soft-delete a brand. **200 with `{"id" => ...}`, not a 204** -- the id
      # it retired is the caller's only confirmation.
      #
      # Refused twice, both as a 409: the DEFAULT brand cannot be deleted, and
      # neither can one any channel still points at (the message carries the
      # count). Conversations, triggers and workflows are left pointing at the
      # tombstone deliberately, so history keeps its branding.
      def delete(id)
        http_delete(expand("#{PATH}/{id}", id))
      end
    end
  end
end
