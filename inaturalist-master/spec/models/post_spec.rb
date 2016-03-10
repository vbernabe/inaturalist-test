require File.dirname(__FILE__) + '/../spec_helper.rb'

describe Post do
  before(:each) { enable_elastic_indexing(Update) }
  after(:each) { disable_elastic_indexing(Update) }

  describe "creation" do
    it "should not generate jobs if it's a draft" do
      friendship = Friendship.make
      user, friend = [friendship.user, friendship.friend]
      expect {
        Post.make(:draft, :user => friend)
      }.to_not change(Delayed::Job, :count)
    end

    it "should not generate an update for the owner" do
      u = User.make!
      post = without_delay {Post.make!(:user => u, :parent => u)}
      expect(Update.where(:notifier_type => "Post", :notifier_id => post.id, :subscriber_id => post.user_id).first).to be_blank
    end

    it "should not be published if user created in the last 24 hours" do
      u = User.make!(:created_at => Time.now)
      p = Post.make(:published_at => Time.now, :user => u)
      expect(p).not_to be_valid
      expect(p.errors[:user]).not_to be_blank
    end
  end

  describe "publish" do
    describe "for a project" do
      let(:project) { Project.make! }
      let(:post) { Post.make!(parent: project, user: project.user) }

      it "should generate an update for a project user" do
        pu = ProjectUser.make!(project: project)
        expect( pu.user.updates.count ).to eq 0
        without_delay do
          post.update_attributes(published_at: Time.now)
        end
        expect( pu.user.updates.last.notifier ).to eq post
      end

      it "should not generate an update for a project user if they don't prefer it" do
        pu = ProjectUser.make!(project: project, prefers_updates: false)
        expect( pu.user.updates.count ).to eq 0
        without_delay do
          post.update_attributes(published_at: Time.now)
        end
        expect( pu.user.updates.count ).to eq 0
      end
    end
  end

  describe "creation for project" do
    it "should generate an update for the owner" do
      p = Project.make!
      u = p.user
      post = without_delay {Post.make!(:user => u, :parent => p)}
      expect(Update.where(:notifier_type => "Post", :notifier_id => post.id, :subscriber_id => post.user_id).first).not_to be_blank
    end
  end

  describe "creation for user" do
    it "should generate updates for followers" do
      f = Friendship.make!
      post = without_delay { Post.make!(:parent => f.friend) }
      expect(Update.where(:notifier_type => "Post", :notifier_id => post.id, :subscriber_id => f.user_id).first).not_to be_blank
    end
  end

  describe "mentions" do
    it "knows what users have been mentioned" do
      u = User.make!
      project = Project.make!
      p = Post.make!(body: "hey @#{ u.login }", parent: project)
      expect( p.mentioned_users ).to eq [ u ]
    end

    it "generates mention updates" do
      u = User.make!
      project = Project.make!
      p = without_delay { Post.make!(body: "hey @#{ u.login }", parent: project) }
      expect( Update.where(notifier: p).mention.count ).to eq 1
      expect( Update.where(notifier: p).mention.first.subscriber ).to eq u
    end
  end
end
