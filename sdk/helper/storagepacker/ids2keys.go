package storagepacker

import (
	"encoding/hex"
	"errors"
	"fmt"
	"github.com/hashicorp/vault/sdk/helper/cryptoutil"
	"math"
	"sort"
	"strings"
)

type itemRequest struct {
	// Item ID, provided by client
	ID string

	// Storage key == hash of ID
	Key string

	// Stored object, nil if not found
	Value *Item
}

func GetItemIDHash(itemID string) string {
	return hex.EncodeToString(cryptoutil.Blake2b256Hash(itemID))
}

// Given a list of IDs, calculate their keys generate itemRequests for each.
func (s *StoragePackerV2) keysForIDs(ids []string) []*itemRequest {
	requests := make([]*itemRequest, 0, len(ids))
	for _, id := range ids {
		requests = append(requests, &itemRequest{
			ID:    id,
			Key:   GetItemIDHash(id),
			Value: nil,
		})
	}
	return requests
}

// Given a list of Items, calculate their keys generate itemRequests for each.
func (s *StoragePackerV2) keysForItems(items []*Item) []*itemRequest {
	requests := make([]*itemRequest, 0, len(items))
	for _, i := range items {
		requests = append(requests, &itemRequest{
			ID:    i.ID,
			Key:   GetItemIDHash(i.ID),
			Value: i,
		})
	}
	return requests
}

// Sort the requests in key order, nondestructively (so we can refer
// back to the original order.)
func sortRequests(requests []*itemRequest) []*itemRequest {
	duplicate := append([]*itemRequest{}, requests...)
	sort.Slice(duplicate, func(i, j int) bool {
		return duplicate[i].Key < duplicate[j].Key
	})
	return duplicate
}

func checkForDuplicateIds(ids []string) (bool, string) {
	idsSeen := make(map[string]bool, len(ids))
	for _, id := range ids {
		if _, found := idsSeen[id]; found {
			return true, id
		}
		idsSeen[id] = true
	}
	return false, ""
}

// Return the topmost bucket in the tree for a given key.
// Used as a defult if the cache is empty or bypassed.
func (s *StoragePackerV2) firstKey(cacheKey string) (string, error) {
	rootShardLength := s.BaseBucketBits / 4
	if len(cacheKey) < rootShardLength {
		return cacheKey, errors.New("Key too short.")
	}
	return cacheKey[0 : s.BaseBucketBits/4], nil
}

// Return all topmost buckets in the tree.
func (s *StoragePackerV2) getAllBaseBucketKeys() []string {
	numBuckets := int(math.Pow(2.0, float64(s.BaseBucketBits)))
	rootBucketLength := s.BaseBucketBits / 4

	// %02x for default configuration, could be %01x, %03x, etc.
	formatString := fmt.Sprintf("%%0%dx", rootBucketLength)

	ret := make([]string, 0, numBuckets)
	for i := 0; i < numBuckets; i++ {
		bucketKey := fmt.Sprintf(formatString, i)
		ret = append(ret, bucketKey)
	}
	return ret
}

// Buckets keys have / in them.
// Entries in the radix tree do not.
// Lock hashing uses the latter form.
func (s *StoragePackerV2) GetCacheKey(key string) string {
	return strings.Replace(key, "/", "", -1)
}