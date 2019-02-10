require 'rails_helper'
require 'models/application_model_examples'
require 'models/concerns/can_be_imported_examples'
require 'models/concerns/can_lookup_examples'

RSpec.describe Ticket, type: :model do
  it_behaves_like 'ApplicationModel'
  it_behaves_like 'CanBeImported'
  it_behaves_like 'CanLookup'

  subject(:ticket) { create(:ticket) }

  describe 'Class methods:' do
    describe '.selectors' do
      # https://github.com/zammad/zammad/issues/1769
      context 'when matching multiple tickets, each with multiple articles' do
        let(:tickets) { create_list(:ticket, 2) }

        before do
          create(:ticket_article, ticket: tickets.first, from: 'asdf1@blubselector.de')
          create(:ticket_article, ticket: tickets.first, from: 'asdf2@blubselector.de')
          create(:ticket_article, ticket: tickets.first, from: 'asdf3@blubselector.de')
          create(:ticket_article, ticket: tickets.last, from: 'asdf4@blubselector.de')
          create(:ticket_article, ticket: tickets.last, from: 'asdf5@blubselector.de')
          create(:ticket_article, ticket: tickets.last, from: 'asdf6@blubselector.de')
        end

        let(:condition) do
          {
            'article.from' => {
              operator: 'contains',
              value:    'blubselector.de',
            },
          }
        end

        it 'returns a list of unique tickets (i.e., no duplicates)' do
          expect(Ticket.selectors(condition, 100, nil, 'full'))
            .to match_array([2, tickets])
        end
      end
    end
  end

  describe 'Instance methods:' do
    describe '#merge_to' do
      let(:target_ticket) { create(:ticket) }

      context 'when source ticket has Links' do
        let(:linked_tickets) { create_list(:ticket, 3) }
        let(:links) { linked_tickets.map { |l| create(:link, from: ticket, to: l) } }

        it 'reassigns all links to the target ticket after merge' do
          expect { ticket.merge_to(ticket_id: target_ticket.id, user_id: 1) }
            .to change { links.each(&:reload).map(&:link_object_source_value) }
            .to(Array.new(3) { target_ticket.id })
        end
      end

      context 'when attempting to cross-merge (i.e., to merge B → A after merging A → B)' do
        before { target_ticket.merge_to(ticket_id: ticket.id, user_id: 1) }

        it 'raises an error' do
          expect { ticket.merge_to(ticket_id: target_ticket.id, user_id: 1) }
            .to raise_error('ticket already merged, no merge into merged ticket possible')
        end
      end

      context 'when attempting to self-merge (i.e., to merge A → A)' do
        it 'raises an error' do
          expect { ticket.merge_to(ticket_id: ticket.id, user_id: 1) }
            .to raise_error("Can't merge ticket with it self!")
        end
      end
    end

    describe '#perform_changes' do
      # Regression test for https://github.com/zammad/zammad/issues/2001
      describe 'argument handling' do
        let(:perform) do
          {
            'notification.email' => {
              body:      "Hello \#{ticket.customer.firstname} \#{ticket.customer.lastname},",
              recipient: %w[article_last_sender ticket_owner ticket_customer ticket_agents],
              subject:   "Autoclose (\#{ticket.title})"
            }
          }
        end

        it 'does not mutate contents of "perform" hash' do
          expect { ticket.perform_changes(perform, 'trigger', {}, 1) }
            .not_to change { perform }
        end
      end

      context 'with "ticket.state_id" key in "perform" hash' do
        let(:perform) do
          {
            'ticket.state_id' => {
              'value' => Ticket::State.lookup(name: 'closed').id
            }
          }
        end

        it 'changes #state to specified value' do
          expect { ticket.perform_changes(perform, 'trigger', ticket, User.first) }
            .to change { ticket.reload.state.name }.to('closed')
        end
      end

      context 'with "ticket.action" => { "value" => "delete" } in "perform" hash' do
        let(:perform) do
          {
            'ticket.state_id' => { 'value' => Ticket::State.lookup(name: 'closed').id.to_s },
            'ticket.action'   => { 'value' => 'delete' },
          }
        end

        it 'performs a ticket deletion on a ticket' do
          expect { ticket.perform_changes(perform, 'trigger', ticket, User.first) }
            .to change { ticket.destroyed? }.to(true)
        end
      end

      context 'with a "notification.email" trigger' do
        # Regression test for https://github.com/zammad/zammad/issues/1543
        #
        # If a new article fires an email notification trigger,
        # and then another article is added to the same ticket
        # before that trigger is performed,
        # the email template's 'article' var should refer to the originating article,
        # not the newest one.
        #
        # (This occurs whenever one action fires multiple email notification triggers.)
        context 'when two articles are created before the trigger fires once (race condition)' do
          let!(:article) { create(:ticket_article, ticket: ticket) }
          let!(:new_article) { create(:ticket_article, ticket: ticket) }

          let(:trigger) do
            build(:trigger,
                  perform: {
                    'notification.email' => {
                      body:      '',
                      recipient: 'ticket_customer',
                      subject:   ''
                    }
                  })
          end

          # required by Ticket#perform_changes for email notifications
          before { article.ticket.group.update(email_address: create(:email_address)) }

          it 'passes the first article to NotificationFactory::Mailer' do
            expect(NotificationFactory::Mailer)
              .to receive(:template)
              .with(hash_including(objects: { ticket: ticket, article: article }))
              .at_least(:once)
              .and_call_original

            expect(NotificationFactory::Mailer)
              .not_to receive(:template)
              .with(hash_including(objects: { ticket: ticket, article: new_article }))

            ticket.perform_changes(trigger.perform, 'trigger', { article_id: article.id }, 1)
          end
        end
      end
    end

    describe '#access?' do
      context 'when given ticket’s owner' do
        it 'returns true for both "read" and "full" privileges' do
          expect(ticket.access?(ticket.owner, 'read')).to be(true)
          expect(ticket.access?(ticket.owner, 'full')).to be(true)
        end
      end

      context 'when given the ticket’s customer' do
        it 'returns true for both "read" and "full" privileges' do
          expect(ticket.access?(ticket.customer, 'read')).to be(true)
          expect(ticket.access?(ticket.customer, 'full')).to be(true)
        end
      end

      context 'when given a user that is neither owner nor customer' do
        let(:user) { create(:agent_user) }

        it 'returns false for both "read" and "full" privileges' do
          expect(ticket.access?(user, 'read')).to be(false)
          expect(ticket.access?(user, 'full')).to be(false)
        end

        context 'but the user is an agent with full access to ticket’s group' do
          before { user.group_names_access_map = { ticket.group.name => 'full' } }

          it 'returns true for both "read" and "full" privileges' do
            expect(ticket.access?(user, 'read')).to be(true)
            expect(ticket.access?(user, 'full')).to be(true)
          end
        end

        context 'but the user is a customer from the same organization as ticket’s customer' do
          subject(:ticket) { create(:ticket, customer: customer) }
          let(:customer) { create(:customer_user, organization: create(:organization)) }
          let(:colleague) { create(:customer_user, organization: customer.organization) }

          context 'and organization.shared is true (default)' do
            it 'returns true for both "read" and "full" privileges' do
              expect(ticket.access?(colleague, 'read')).to be(true)
              expect(ticket.access?(colleague, 'full')).to be(true)
            end
          end

          context 'but organization.shared is false' do
            before { customer.organization.update(shared: false) }

            it 'returns false for both "read" and "full" privileges' do
              expect(ticket.access?(colleague, 'read')).to be(false)
              expect(ticket.access?(colleague, 'full')).to be(false)
            end
          end
        end
      end
    end
  end

  describe 'Attributes:' do
    describe '#pending_time' do
      subject(:ticket) { create(:ticket, pending_time: Time.zone.now + 2.days) }

      context 'when #state is updated to any non-"pending" value' do
        it 'is reset to nil' do
          expect { ticket.update!(state: Ticket::State.lookup(name: 'open')) }
            .to change { ticket.pending_time }.to(nil)
        end
      end

      # Regression test for commit 92f227786f298bad1ccaf92d4478a7062ea6a49f
      context 'when #state is updated to nil (violating DB NOT NULL constraint)' do
        it 'does not prematurely raise within the callback (#reset_pending_time)' do
          expect { ticket.update!(state: nil) }
            .to raise_error(ActiveRecord::StatementInvalid)
        end
      end
    end
  end

  describe 'Callbacks & Observers -' do
    describe 'NULL byte handling (via ChecksAttributeValuesAndLength concern):' do
      it 'removes them from title on creation, if necessary (postgres doesn’t like them)' do
        expect { create(:ticket, title: "some title \u0000 123") }
          .not_to raise_error
      end
    end

    describe 'Association & attachment management:' do
      it 'deletes all related ActivityStreams on destroy' do
        create_list(:activity_stream, 3, o: ticket)

        expect { ticket.destroy }
          .to change { ActivityStream.exists?(activity_stream_object_id: ObjectLookup.by_name('Ticket'), o_id: ticket.id) }
          .to(false)
      end

      it 'deletes all related Links on destroy' do
        create(:link, from: ticket, to: create(:ticket))
        create(:link, from: create(:ticket), to: ticket)
        create(:link, from: ticket, to: create(:ticket))

        expect { ticket.destroy }
          .to change { Link.where('link_object_source_value = :id OR link_object_target_value = :id', id: ticket.id).any? }
          .to(false)
      end

      it 'deletes all related Articles on destroy' do
        create_list(:ticket_article, 3, ticket: ticket)

        expect { ticket.destroy }
          .to change { Ticket::Article.exists?(ticket: ticket) }
          .to(false)
      end

      it 'deletes all related OnlineNotifications on destroy' do
        create_list(:online_notification, 3, o: ticket)

        expect { ticket.destroy }
          .to change { OnlineNotification.where(object_lookup_id: ObjectLookup.by_name('Ticket'), o_id: ticket.id).any? }
          .to(false)
      end

      it 'deletes all related Tags on destroy' do
        create_list(:tag, 3, o: ticket)

        expect { ticket.destroy }
          .to change { Tag.exists?(tag_object_id: Tag::Object.lookup(name: 'Ticket').id, o_id: ticket.id) }
          .to(false)
      end

      it 'deletes all related Histories on destroy' do
        create_list(:history, 3, o: ticket)

        expect { ticket.destroy }
          .to change { History.exists?(history_object_id: History::Object.lookup(name: 'Ticket').id, o_id: ticket.id) }
          .to(false)
      end

      it 'deletes all related Karma::ActivityLogs on destroy' do
        create_list(:'karma/activity_log', 3, o: ticket)

        expect { ticket.destroy }
          .to change { Karma::ActivityLog.exists?(object_lookup_id: ObjectLookup.by_name('Ticket'), o_id: ticket.id) }
          .to(false)
      end

      it 'deletes all related RecentViews on destroy' do
        create_list(:recent_view, 3, o: ticket)

        expect { ticket.destroy }
          .to change { RecentView.exists?(recent_view_object_id: ObjectLookup.by_name('Ticket'), o_id: ticket.id) }
          .to(false)
      end

      context 'when ticket is generated from email (with attachments)' do
        subject(:ticket) { Channel::EmailParser.new.process({}, raw_email).first }
        let(:raw_email) { File.read(Rails.root.join('test', 'data', 'mail', 'mail001.box')) }

        it 'adds attachments to the Store{::File,::Provider::DB} tables' do
          expect { ticket }
            .to change { Store.count }.by(2)
            .and change { Store::File.count }.by(2)
            .and change { Store::Provider::DB.count }.by(2)
        end

        context 'and subsequently destroyed' do
          it 'deletes all related attachments' do
            ticket  # create ticket

            expect { ticket.destroy }
              .to change { Store.count }.by(-2)
              .and change { Store::File.count }.by(-2)
              .and change { Store::Provider::DB.count }.by(-2)
          end
        end

        context 'and a duplicate ticket is generated from the same email' do
          before { ticket }  # create ticket
          let(:duplicate) { Channel::EmailParser.new.process({}, raw_email).first }

          it 'adds duplicate attachments to the Store table only' do
            expect { duplicate }
              .to change { Store.count }.by(2)
              .and change { Store::File.count }.by(0)
              .and change { Store::Provider::DB.count }.by(0)
          end

          context 'when only the duplicate ticket is destroyed' do
            it 'deletes only the duplicate attachments' do
              duplicate  # create ticket

              expect { duplicate.destroy }
                .to change { Store.count }.by(-2)
                .and change { Store::File.count }.by(0)
                .and change { Store::Provider::DB.count }.by(0)
            end
          end

          context 'when only the duplicate ticket is destroyed' do
            it 'deletes all related attachments' do
              duplicate.destroy

              expect { ticket.destroy }
                .to change { Store.count }.by(-2)
                .and change { Store::File.count }.by(-2)
                .and change { Store::Provider::DB.count }.by(-2)
            end
          end
        end
      end
    end
  end
end
